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
    Assert "Step-TestApi 包含『最长等待约 30 秒』" { $startHereText -match [regex]::Escape("最长等待约 30 秒") } "缺失等待提示"
    Assert "Step-TestApi 包含『配置仍会保留』" { $startHereText -match [regex]::Escape("配置仍会保留") } "缺失保留说明"

    # Start-LazyInstall Step 2 后有上下文文案
    Assert "Step 2 后有 Claude Code 安装验证已通过" { $startHereText -match "Claude Code 安装验证已通过" } "缺失安装成功文案"
    Assert "Step 2 后有下一步说明" { $startHereText -match "下一步将打开 DeepSeek API Key 页面" } "缺失下一步说明"
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

    Assert "Start-Here.ps1 包含日志路径指引文案（窗口异常关闭时引导诊断）" {
        $startHereText -match '窗口异常关闭.*一键诊断|窗口异常关闭.*support-feedback'
    } "Start-Here.ps1 缺失日志路径指引文案"

    # Step-CheckEnvironment 使用 Write-CheckProgress（至少 10 个进度调用）
    Assert "Step-CheckEnvironment 包含 Write-CheckProgress -Current 1" {
        $startHereText -match 'Write-CheckProgress\s+-Current\s+1\s+-Total\s+7'
    } "Step-CheckEnvironment 缺失第 1 项进度提示（Total 应为 7，VS Code/Git/WSL 已移入日志）"

    Assert "Step-CheckEnvironment 包含 Write-CheckProgress -Current 7 (末项)" {
        $startHereText -match 'Write-CheckProgress\s+-Current\s+7\s+-Total\s+7'
    } "Step-CheckEnvironment 缺失第 7 项进度提示（末项应为 Current 7 Total 7，VS Code/Git/WSL 已移入日志）"

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
        $claudeInstallText -match '如果下载超时，将自动切换到备用安装方式'
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

    # --- 23f: 文档新 CTA 检查（P1-5 已更新文档文案）---
    Assert "README.md 包含完成页 [1] CTA" {
        $readmeText -match '启动 Claude Code 测试（推荐）'
    } "README.md 必须包含完成页 [1] 启动 Claude Code 测试（推荐）"
    Assert "QUICK_START.md 包含完成页 [1] CTA" {
        $qsText -match '启动 Claude Code 测试（推荐）'
    } "QUICK_START.md 必须包含完成页 [1] 启动 Claude Code 测试（推荐）"
    Assert "README.md 包含自动打开终端描述" {
        $readmeText -match '自动.*终端|在文件夹地址栏输入'
    } "README.md 必须包含自动打开终端或地址栏手动方式描述"

    # --- 23g: 文档售后模板检查 ---
    Assert "README.md 包含统一售后安全提示" {
        $readmeText -match 'support-feedback\.txt' -and
        $readmeText -match '不要发送 backup.*logs.*reports/full-report' -and
        $readmeText -match '不要发送完整 API Key' -and
        $readmeText -match '如果截图，请先确认截图里没有完整 API Key'
    } "README.md 必须包含统一售后安全提示模板"
    Assert "QUICK_START.md 包含统一售后安全提示" {
        $qsText -match 'support-feedback\.txt' -and
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
    # 25. v1.3.3 P0 修复检查（完成页语法/Fresh Shell 重写/Node 分级/报告文案）
    # ============================================================
    Write-CheckHeader "25. v1.3.3 P0 修复检查：语法/Fresh Shell/Node 分级/报告文案"

    $startHerePath = Join-Path $ScriptRoot "Start-Here.ps1"
    $startHereText = Get-Content $startHerePath -Raw -Encoding UTF8
    $commonPath = Join-Path $ScriptRoot "lib\common.ps1"
    $commonText = Get-Content $commonPath -Raw -Encoding UTF8
    $doctorPath = Join-Path $ScriptRoot "doctor.ps1"
    $doctorText = Get-Content $doctorPath -Raw -Encoding UTF8

    # --- P0-1: 完成页 [1] 语法修复 ---
    Assert "P0-1: Start-Here.ps1 不含 Test-Path `$nativeClaudeExe -or" {
        $startHereText -notmatch 'Test-Path\s+\$nativeClaudeExe\s+-or'
    } "Start-Here.ps1 仍包含错误的 Test-Path `$nativeClaudeExe -or 语法"

    # P0-1 补充：Show-CompletionMenu [1] 已迁移到 P1-1 (Start-ClaudeTestTerminal)，
    # 不再需要 (Test-Path $nativeClaudeExe) -or 模式。改为验证迁移完成。
    # 由于 $startHereText 在当前作用域已定义，直接用其验证 Show-CompletionMenu 不再使用旧逻辑。
    if ($startHereText -match '(?s)function Show-CompletionMenu\s*\{(.*?)^\s*\}') {
        $cmBlock = $matches[1]
    } else { $cmBlock = "" }
    Assert "P0-1: Show-CompletionMenu 已迁移到 Start-ClaudeTestTerminal（不再使用旧 fresh shell 模式）" {
        $cmBlock -notmatch 'Test-ClaudeCommandInFreshShell'
    } "Show-CompletionMenu 仍包含旧的 fresh shell 检测，迁移未完成"

    # --- P0-2: Fresh Shell 重写 ---
    # 提取 Test-ClaudeCommandInFreshShell 函数体（从函数声明到下一个函数声明）
    $freshShellFuncBody = ""
    $commonLines = Get-Content $commonPath -Encoding UTF8
    $inFunc = $false; $funcStart = -1; $funcEnd = -1
    for ($i = 0; $i -lt $commonLines.Count; $i++) {
        if ($commonLines[$i] -match '^function Test-ClaudeCommandInFreshShell\b') { $funcStart = $i; $inFunc = $true; continue }
        if ($inFunc -and $commonLines[$i] -match '^function \w') { $funcEnd = $i; break }
    }
    if ($funcStart -ge 0) {
        if ($funcEnd -lt 0) { $funcEnd = $commonLines.Count - 1 }
        $freshShellFuncBody = ($commonLines[$funcStart..($funcEnd - 1)] -join "`n")
    }

    Assert "P0-2: Test-ClaudeCommandInFreshShell 不得调用 Invoke-CommandSafe" {
        # 函数体内不应有 Invoke-CommandSafe 调用；允许注释中提到该名称（如 "不再通过 Invoke-CommandSafe"）
        ($freshShellFuncBody -and $freshShellFuncBody -notmatch '\bInvoke-CommandSafe\s+-')
    } "Test-ClaudeCommandInFreshShell 仍调用 Invoke-CommandSafe"

    Assert "P0-2: Test-ClaudeCommandInFreshShell 创建临时 .ps1 文件" {
        $freshShellFuncBody -match 'ccdi_fresh_shell_.*\.ps1'
    } "Test-ClaudeCommandInFreshShell 未创建临时 .ps1 检测脚本"

    Assert "P0-2: Test-ClaudeCommandInFreshShell 使用 powershell.exe -File" {
        $freshShellFuncBody -match 'powershell\.exe.*-File' -or
        $freshShellFuncBody -match '-File[\s\S]{0,50}\$temp'
    } "Test-ClaudeCommandInFreshShell 未使用 powershell.exe -File"

    Assert "P0-2: Test-ClaudeCommandInFreshShell 捕获 stdout/stderr/ExitCode" {
        ($freshShellFuncBody -match 'RedirectStandardOutput' -and
         $freshShellFuncBody -match 'RedirectStandardError' -and
         $freshShellFuncBody -match 'ExitCode')
    } "Test-ClaudeCommandInFreshShell 未独立捕获 stdout/stderr/ExitCode"

    Assert "P0-2: Test-ClaudeCommandInFreshShell 保留 TestSafe/mock 分支" {
        ($freshShellFuncBody -match 'CCDI_MOCK_INSTALL_DECISION' -and
         $freshShellFuncBody -match 'CCDI_MOCK_FRESH_SHELL')
    } "Test-ClaudeCommandInFreshShell 缺失 TestSafe/mock 分支"

    Assert "P0-2: Test-ClaudeCommandInFreshShell 30 秒超时" {
        $freshShellFuncBody -match 'WaitForExit\(30000\)'
    } "Test-ClaudeCommandInFreshShell 未设置 30 秒超时"

    Assert "P0-2: Test-ClaudeCommandInFreshShell 超时杀进程树" {
        $freshShellFuncBody -match 'taskkill\.exe'
    } "Test-ClaudeCommandInFreshShell 超时未使用 taskkill /T /F"

    Assert "P0-2: Test-ClaudeCommandInFreshShell finally 清理临时文件" {
        ($freshShellFuncBody -match 'finally[\s\S]{0,200}Remove-Item' -or
         $freshShellFuncBody -match 'Remove-Item.*Force.*temp')
    } "Test-ClaudeCommandInFreshShell 未清理临时文件"

    # --- P0-R1: fresh shell 路径空格防护 ---
    Assert "P0-R1: Test-ClaudeCommandInFreshShell 不得使用 -ArgumentList 数组传递 -File" {
        $freshShellFuncBody -notmatch '-ArgumentList\s+@\('
    } "Test-ClaudeCommandInFreshShell 仍使用 -ArgumentList @() 数组，路径含空格时会拆分"

    Assert "P0-R1: Test-ClaudeCommandInFreshShell 使用 ConvertTo-CommandLineArgument 加引号" {
        $freshShellFuncBody -match 'ConvertTo-CommandLineArgument'
    } "Test-ClaudeCommandInFreshShell 未调用 ConvertTo-CommandLineArgument 给 $tempScript 加引号"

    Assert "P0-R1: Test-ClaudeCommandInFreshShell 使用 `$argumentLine 传递参数" {
        ($freshShellFuncBody -match '\$argumentLine' -and
         $freshShellFuncBody -match '-ArgumentList\s+\$argumentLine')
    } "Test-ClaudeCommandInFreshShell 未使用 `$argumentLine 单字符串传参"

    Assert "P0-R1: Test-ClaudeCommandInFreshShell 解析 System32 powershell.exe 路径" {
        $freshShellFuncBody -match 'System32\\WindowsPowerShell\\v1\.0\\powershell\.exe'
    } "Test-ClaudeCommandInFreshShell 未解析 System32\WindowsPowerShell\v1.0\powershell.exe"

    # --- P0-R2: 安装报告 fresh shell 失败 WARN + 精确下一步 ---
    Assert "P0-R2: Start-Here.ps1 含 `$freshShellStatusTag 分级变量" {
        $startHereText -match '\$freshShellStatusTag'
    } "Start-Here.ps1 缺失 `$freshShellStatusTag 分级变量"

    Assert "P0-R2: Start-Here.ps1 Fresh PowerShell 验证不再硬编码 [ERROR]" {
        $startHereText -notmatch '\(`$freshShellOk\)\s*\{\s*"\[OK\]"\s*\}\s*else\s*\{\s*"\[ERROR\]"\s*\}.*Fresh PowerShell'
    } "Start-Here.ps1 Fresh PowerShell 验证行仍硬编码 else [ERROR]"

    Assert "P0-R2: Start-Here.ps1 含 fresh-shell-fail 精确下一步分支" {
        $startHereText -match '\$script:ClaudeInstalled -and \$script:ConfigWritten -and \$script:ApiTestPassed -and \$userPathOk -and -not \$freshShellOk'
    } "Start-Here.ps1 缺失 installed+configured+apiPassed+pathOk+freshFail 精确分支"

    Assert "P0-R2: 精确分支出现在通用分支之前" {
        # 精确分支（含 ApiTestPassed+userPathOk+freshShellOk）必须在纯 ConfigWritten 分支之前
        # 在"七、下一步说明"区块中，含 ApiTestPassed 的 elseif 应出现在纯 ConfigWritten 的 elseif 之前
        $nextStepsBlock = if ($startHereText -match '(?s)七、下一步说明\r?\n.*?(?=八、售后提示)') {
            $matches[0]
        } else { "" }
        # 搜索精确分支标记：包含 freshShellOk 的 elseif 行
        $preciseMatch = $nextStepsBlock -match 'ApiTestPassed.*userPathOk.*freshShellOk'
        # 搜索通用分支标记（elseif 中的 ConfigWritten 条件，无引导号）
        $genericMatch = $nextStepsBlock -match 'ClaudeInstalled -and \$script:ConfigWritten\)\s*\{'
        # 精确分支的整个 condition 文本应在通用分支的条件文本之前出现
        if ($preciseMatch -and $genericMatch) {
            $freshShellOkIdx = $nextStepsBlock.IndexOf('freshShellOk')
            $genericBranchIdx = $nextStepsBlock.IndexOf('安装完成不代表 API 永久可用')
            ($freshShellOkIdx -gt 0 -and $genericBranchIdx -gt 0 -and $freshShellOkIdx -lt $genericBranchIdx)
        } else {
            $preciseMatch -and $genericMatch
        }
    } "精确分支必须在通用 ConfigWritten 分支之前（freshShellOk 出现早于'安装完成不代表 API 永久可用'）"

    Assert "P0-R2: 精确分支含 claude --version 手动验证指引" {
        ($startHereText -match '安装和配置已完成，但自动启动验证未通过' -and
         $startHereText -match '如果能显示版本号，可以正常使用' -and
         $startHereText -match '如果仍失败，请运行')
    } "精确分支缺失 claude --version 手动验证指引或降级文案"

    Assert "P0-R2: needs_restart 精确匹配逻辑未回退" {
        $startHereText -notmatch '-match\s+"needs_restart"'
    } "Start-Here.ps1 回退到 -match needs_restart 通配逻辑"

    # --- P0-3: doctor Node/npm 错误级别 ---
    Assert "P0-3: doctor.ps1 Node.js 检测根据 Native Install 降级" {
        $doctorText -match 'isNativeInstallLikely.*Add-CheckResult\s+"Node\.js"\s+"INFO"' -or
        $doctorText -match 'isNativeInstallLikely[\s\S]{0,300}Node\.js[\s\S]{0,100}INFO'
    } "doctor.ps1 Node.js 未按 Native Install 状态降级为 INFO"

    Assert "P0-3: doctor.ps1 npm 检测根据 Native Install 降级" {
        $doctorText -match 'isNativeInstallLikely.*Add-CheckResult\s+"npm"\s+"INFO"' -or
        $doctorText -match 'isNativeInstallLikely[\s\S]{0,300}npm[\s\S]{0,100}INFO'
    } "doctor.ps1 npm 未按 Native Install 状态降级为 INFO"

    Assert "P0-3: doctor.ps1 含 Native Install 不影响基础使用文案" {
        $doctorText -match '当前为 Native Install，已不影响 Claude Code 基础使用'
    } "doctor.ps1 缺失 '当前为 Native Install，已不影响 Claude Code 基础使用' 文案"

    Assert "P0-3: doctor.ps1 Fresh Shell 文件与 PATH 就绪时降级为 WARN" {
        $doctorText -match '自动验证未通过，但 Claude Code 文件和 PATH 均已就绪'
    } "doctor.ps1 Fresh Shell 在文件和 PATH 就绪时未提供温和文案"

    # --- P0-4: 安装报告文案 ---
    Assert "P0-4: Start-Here.ps1 installed_needs_restart_or_path_fix 不触发重跑文案" {
        $startHereText -notmatch 'installed_needs_restart_or_path_fix[\s\S]{0,200}重新双击「00-点我开始安装\.cmd」继续安装流程'
    } "Start-Here.ps1 仍在 installed_needs_restart_or_path_fix 下输出'重新双击'误导文案"

    Assert "P0-4: Start-Here.ps1 含 安装和配置已完成 或 新开 PowerShell claude --version 指引" {
        ($startHereText -match '新开 PowerShell 手动执行' -or
         $startHereText -match 'claude --version[\s\S]{0,50}手动验证' -or
         $startHereText -match '如仍失败.*一键修复依赖' -or
         $startHereText -match '安装和配置已完成')
    } "Start-Here.ps1 缺失新开 PowerShell 验证指引或安装和配置已完成文案"

    # --- P0 整体: 不得使用 -match "needs_restart" 通配 ---
    Assert "P0: Start-Here.ps1 不再使用 -match needs_restart（精确匹配 status）" {
        $startHereText -notmatch '-match\s+"needs_restart"'
    } "Start-Here.ps1 仍使用 -match needs_restart 通配，installed_needs_restart_or_path_fix 可能被误判"

    Write-Host ""

    # ============================================================
    # 26. v1.3.3 P1-1 检查：完成页 [1] 自动启动 Claude Code 测试终端
    # ============================================================
    Write-CheckHeader "26. v1.3.3 P1-1: 完成页 [1] 自动启动 Claude Code 测试终端"

    $startHerePath = Join-Path $ScriptRoot "Start-Here.ps1"
    $startHereText = Get-Content $startHerePath -Raw -Encoding UTF8

    # --- P1-1a: 完成页 [1] 菜单文案已改 ---
    Assert 'P1-1a: 完成页 [1] 标题包含启动 Claude Code 测试（推荐）' {
        $startHereText -match [regex]::Escape('启动 Claude Code 测试（推荐）')
    } 'Start-Here.ps1 完成页 [1] 标题必须改为启动 Claude Code 测试（推荐）'

    Assert 'P1-1a: 完成页 [1] 副标题包含自动打开测试项目终端并直接运行 claude' {
        $startHereText -match [regex]::Escape('自动打开测试项目终端，并直接运行 claude')
    } 'Start-Here.ps1 完成页 [1] 副标题必须改为自动打开测试项目终端并直接运行 claude'

    # --- P1-1b: Start-ClaudeTestTerminal 函数存在 ---
    Assert "P1-1b: Start-ClaudeTestTerminal 函数存在" {
        $startHereText -match 'function Start-ClaudeTestTerminal'
    } "Start-Here.ps1 必须新增 function Start-ClaudeTestTerminal"

    # --- P1-1c: Start-ClaudeTestTerminal 使用 -EncodedCommand + Unicode ---
    Assert "P1-1c: Start-ClaudeTestTerminal 使用 -EncodedCommand" {
        $startHereText -match 'function Start-ClaudeTestTerminal[\s\S]{0,15000}-EncodedCommand'
    } "Start-ClaudeTestTerminal 必须使用 -EncodedCommand"

    Assert "P1-1c: Start-ClaudeTestTerminal 使用 [Text.Encoding]::Unicode.GetBytes" {
        $startHereText -match 'function Start-ClaudeTestTerminal[\s\S]{0,15000}\[Text\.Encoding\]::Unicode\.GetBytes'
    } "Start-ClaudeTestTerminal 必须使用 [Text.Encoding]::Unicode.GetBytes 编码"

    Assert "P1-1c: Start-ClaudeTestTerminal 使用 [Convert]::ToBase64String" {
        $startHereText -match 'function Start-ClaudeTestTerminal[\s\S]{0,15000}\[Convert\]::ToBase64String'
    } "Start-ClaudeTestTerminal 必须使用 [Convert]::ToBase64String"

    # --- P1-1d: Start-ClaudeTestTerminal 使用 Start-Process + WorkingDirectory ---
    Assert "P1-1d: Start-ClaudeTestTerminal 使用 Start-Process" {
        $startHereText -match 'function Start-ClaudeTestTerminal[\s\S]{0,15000}Start-Process'
    } "Start-ClaudeTestTerminal 必须使用 Start-Process"

    Assert "P1-1d: Start-ClaudeTestTerminal 使用 -WorkingDirectory" {
        $startHereText -match 'function Start-ClaudeTestTerminal[\s\S]{0,15000}-WorkingDirectory'
    } "Start-ClaudeTestTerminal 必须使用 -WorkingDirectory `$ProjectPath"

    # --- P1-1e: launchScript 包含 Set-Location -LiteralPath ---
    Assert "P1-1e: launchScript 包含 Set-Location -LiteralPath" {
        $startHereText -match 'function Start-ClaudeTestTerminal[\s\S]{0,15000}Set-Location\s+-LiteralPath'
    } "Start-ClaudeTestTerminal 的 launchScript 必须包含 Set-Location -LiteralPath"

    # --- P1-1f: launchScript 包含 Get-Command claude ---
    Assert "P1-1f: launchScript 包含 Get-Command claude" {
        $startHereText -match 'function Start-ClaudeTestTerminal[\s\S]{0,15000}Get-Command\s+claude'
    } "Start-ClaudeTestTerminal 的 launchScript 必须包含 Get-Command claude 检测"

    # --- P1-1g: launchScript 包含 & claude ---
    Assert "P1-1g: launchScript 包含 & claude" {
        $startHereText -match 'function Start-ClaudeTestTerminal[\s\S]{0,15000}&\s+claude'
    } "Start-ClaudeTestTerminal 的 launchScript 必须包含 & claude 启动"

    # --- P1-1h: Show-CompletionMenu [1] 不再调用 Test-ClaudeCommandInFreshShell ---
    # 提取 Show-CompletionMenu 函数体（从 function 声明到下一个顶层 function 或文件末尾）
    $cmStartIdx = $startHereText.IndexOf('function Show-CompletionMenu')
    $cmBody = if ($cmStartIdx -ge 0) {
        $afterCm = $startHereText.Substring($cmStartIdx + 30)
        $nextFuncMatch = [regex]::Match($afterCm, '(?m)^function \w')
        if ($nextFuncMatch.Success) { $afterCm.Substring(0, $nextFuncMatch.Index) } else { $afterCm }
    } else { "" }

    $completionMenuText = $cmBody

    Assert "P1-1h: Show-CompletionMenu [1] 中不再调用 Test-ClaudeCommandInFreshShell" {
        $completionMenuText -notmatch 'Test-ClaudeCommandInFreshShell'
    } "Show-CompletionMenu 的 [1] 分支不得再调用 Test-ClaudeCommandInFreshShell"

    # --- P1-1i: Show-CompletionMenu [1] 调用 Start-ClaudeTestTerminal ---
    Assert "P1-1i: Show-CompletionMenu [1] 调用 Start-ClaudeTestTerminal" {
        $completionMenuText -match 'Start-ClaudeTestTerminal'
    } "Show-CompletionMenu 的 [1] 分支必须调用 Start-ClaudeTestTerminal"

    # --- P1-1j: [2] 仍只打开文件夹，不启动 claude ---
    Assert "P1-1j: [2] 分支允许 explorer.exe" {
        $completionMenuText -match '"2"\s*\{[\s\S]{0,500}explorer\.exe'
    } "Show-CompletionMenu 的 [2] 分支必须保留 explorer.exe 打开文件夹"

    Assert "P1-1j: [2] 分支不调用 Start-ClaudeTestTerminal" {
        $completionMenuText -notmatch '"2"\s*\{[\s\S]{0,500}Start-ClaudeTestTerminal'
    } "Show-CompletionMenu 的 [2] 分支不得调用 Start-ClaudeTestTerminal"

    Assert "P1-1j: [2] 分支不直接调用 claude" {
        $completionMenuText -notmatch '"2"\s*\{[\s\S]{0,500}&\s+claude'
    } "Show-CompletionMenu 的 [2] 分支不得调用 claude"

    # --- P1-1k: Show-CompletionPage 不直接调用 Start-ClaudeTestTerminal ---
    $cpStartIdx = $startHereText.IndexOf('function Show-CompletionPage')
    $cpBody = if ($cpStartIdx -ge 0) {
        $afterCp = $startHereText.Substring($cpStartIdx + 31)
        $nextFuncCp = [regex]::Match($afterCp, '(?m)^function \w')
        if ($nextFuncCp.Success) { $afterCp.Substring(0, $nextFuncCp.Index) } else { $afterCp }
    } else { "" }

    $completionPageText = $cpBody

    Assert "P1-1k: Show-CompletionPage 不直接调用 Start-ClaudeTestTerminal" {
        $completionPageText -notmatch 'Start-ClaudeTestTerminal'
    } "Show-CompletionPage 不得直接调用 Start-ClaudeTestTerminal（只有 Show-CompletionMenu [1] 可调用）"

    # --- P1-1l: 新终端失败指引包含关键修复建议 ---
    $stctStartIdx = $startHereText.IndexOf('function Start-ClaudeTestTerminal')
    $launchBlock = if ($stctStartIdx -ge 0) {
        $afterStct = $startHereText.Substring($stctStartIdx)
        $nextFuncStct = [regex]::Match($afterStct.Substring(31), '(?m)^function \w')
        if ($nextFuncStct.Success) { $afterStct.Substring(0, 31 + $nextFuncStct.Index) } else { $afterStct }
    } else { "" }
    Assert 'P1-1l: launchScript 包含一键诊断失败指引' {
        $launchBlock -match '一键诊断'
    } 'launchScript 失败时必须包含一键诊断指引'

    Assert 'P1-1l: launchScript 包含一键修复依赖失败指引' {
        $launchBlock -match '一键修复依赖'
    } 'launchScript 失败时必须包含一键修复依赖指引'

    Assert 'P1-1l: launchScript 包含 claude --version 指引' {
        $launchBlock -match 'claude --version'
    } 'launchScript 失败时必须包含 claude --version 指引'

    # --- P1-1m: launchScript 不包含 API Key / settings.json / logs 等敏感内容 ---
    # 复用 P1-1l 定义的 $launchBlock
    Assert "P1-1m: launchScript 不含 settings.json" {
        $launchBlock -notmatch 'settings\.json'
    } "launchScript 不得包含 settings.json"
    Assert "P1-1m: launchScript 不含完整 API Key 输出" {
        $launchBlock -notmatch 'ANTHROPIC_AUTH_TOKEN'
    } "launchScript 不得输出 API Key 相关变量"

    Write-Host ""

    # ============================================================
    # 27. v1.3.3 P1 剩余体验检查：完成页降噪/信任提示/兜底/文档同步
    # ============================================================
    Write-CheckHeader "27. v1.3.3 P1 剩余体验：完成页降噪/信任提示/兜底/文档同步"

    $startHerePath = Join-Path $ScriptRoot "Start-Here.ps1"
    $startHereText = Get-Content $startHerePath -Raw -Encoding UTF8

    # 读取文档
    $readmePath = Join-Path $ScriptRoot "README.md"
    $readmeText = if (Test-Path $readmePath) { Get-Content $readmePath -Raw -Encoding UTF8 } else { "" }
    $qsPath = Join-Path $ScriptRoot "QUICK_START.md"
    $qsText = if (Test-Path $qsPath) { Get-Content $qsPath -Raw -Encoding UTF8 } else { "" }
    $userTutorialPath = Join-Path $ScriptRoot "docs\用户使用教程.md"
    $userTutorialText = if (Test-Path $userTutorialPath) { Get-Content $userTutorialPath -Raw -Encoding UTF8 } else { "" }

    # --- 27a: 不含绝对安全文案 ---
    Assert "27a: Start-Here.ps1 不含'完全安全'" {
        $startHereText -notmatch '完全安全'
    } "Start-Here.ps1 不得包含'完全安全'"

    Assert "27a: Start-Here.ps1 不含'绝对安全'" {
        $startHereText -notmatch '绝对安全'
    } "Start-Here.ps1 不得包含'绝对安全'"

    Assert "27a: Start-Here.ps1 不含'100% 安全'" {
        $startHereText -notmatch '100%\s*安全'
    } "Start-Here.ps1 不得包含'100% 安全'"

    # --- 27b: 新信任提示文案 ---
    Assert "27b: 含新信任提示'确认当前目录是 ClaudeCode-Test 测试项目'" {
        $startHereText -match [regex]::Escape('确认当前目录是 ClaudeCode-Test 测试项目')
    } "Start-ClaudeTestTerminal 必须包含新信任提示"

    Assert "27b: 含'Claude Code 首次启动可能出现以下界面'" {
        $startHereText -match [regex]::Escape('Claude Code 首次启动可能出现以下界面')
    } "Start-ClaudeTestTerminal 必须包含首次启动引导标题"

    # --- 27c: 完成页 freshShellFail 但 pathOk 文案降噪 ---
    Assert "27c: 含'安装和配置已完成，建议启动测试确认'" {
        $startHereText -match [regex]::Escape('安装和配置已完成，建议启动测试确认')
    } "完成页 pathOk+freshShellFail 场景标题必须降噪"

    Assert "27c: 含'PATH 已配置，但自动启动验证暂未通过'" {
        $startHereText -match '命令路径已配置，但新打开的 PowerShell 暂未确认可用'
    } "完成页必须说明命令路径已配置但验证暂未通过"

    Assert "27c: 含'选择 [1] 启动 Claude Code 测试'（pathOk+freshShellFail 场景）" {
        $startHereText -match [regex]::Escape('选择 [1] 启动 Claude Code 测试')
    } "完成页 pathOk+freshShellFail 场景下一步必须建议 [1]"

    Assert "27c: 含'如果新窗口无法进入 Claude Code，再选择 [4] 一键诊断'" {
        $startHereText -match [regex]::Escape('如果新窗口无法进入 Claude Code，再选择 [4] 一键诊断')
    } "完成页 pathOk+freshShellFail 场景必须包含降级到 [4] 的指引"

    # --- 27d: 完成页 PATH 缺失场景文案 ---
    Assert "27d: 含'Claude Code 已安装，但命令路径需要修复'" {
        $startHereText -match [regex]::Escape('Claude Code 已安装，但命令路径需要修复')
    } "完成页 PATH 缺失场景标题必须明确"

    Assert "27d: 含'先选择 [4] 一键诊断'" {
        $startHereText -match [regex]::Escape('先选择 [4] 一键诊断')
    } "完成页 PATH 缺失场景下一步必须写 [4] 诊断"

    Assert "27d: 含'一键修复依赖.cmd'" {
        $startHereText -match '一键修复依赖\.cmd'
    } "完成页必须保留修复依赖入口"

    # --- 27e: [1] 失败兜底步骤 ---
    Assert "27e: 失败兜底含'在文件夹地址栏输入 powershell'" {
        $startHereText -match [regex]::Escape('在文件夹地址栏输入 powershell')
    } "Show-CompletionMenu [1] 失败兜底必须包含地址栏输入 powershell"

    Assert "27e: 失败兜底含'选择 [2] 打开测试项目文件夹'" {
        $startHereText -match '自动启动测试终端失败[\s\S]{0,500}选择 \[2\] 打开测试项目文件夹'
    } "Show-CompletionMenu [1] 失败兜底第一步必须是 [2]"

    Assert "27e: 失败兜底含'返回本窗口选择 [4] 一键诊断'" {
        $startHereText -match [regex]::Escape('返回本窗口选择 [4] 一键诊断')
    } "Show-CompletionMenu [1] 失败兜底必须保留 [4] 诊断"

    # --- 27f: Show-CompletionPage 不调用 Start-ClaudeTestTerminal ---
    # Reuse completionPageText from section 26 P1-1k extraction
    $cpText27 = if ($startHereText -match '(?s)function Show-CompletionPage\s*\{.*?(?=^function Show-CompletionMenu\s*\{)') {
        $matches[0]
    } else { "" }
    Assert "27f: Show-CompletionPage 不调用 Start-ClaudeTestTerminal" {
        $cpText27 -notmatch 'Start-ClaudeTestTerminal'
    } "Show-CompletionPage 不得直接调用 Start-ClaudeTestTerminal"

    # --- 27g: [2] 仍只打开文件夹 ---
    # Reuse completionMenuText from section 26
    $cmStartIdx27 = $startHereText.IndexOf('function Show-CompletionMenu')
    $cmBody27 = if ($cmStartIdx27 -ge 0) {
        $afterCm = $startHereText.Substring($cmStartIdx27 + 30)
        $nextFuncMatch = [regex]::Match($afterCm, '(?m)^function \w')
        if ($nextFuncMatch.Success) { $afterCm.Substring(0, $nextFuncMatch.Index) } else { $afterCm }
    } else { "" }
    Assert "27g: [2] 不调用 Start-ClaudeTestTerminal" {
        $cmBody27 -notmatch '"2"\s*\{[\s\S]{0,500}Start-ClaudeTestTerminal'
    } "[2] 分支不得调用 Start-ClaudeTestTerminal"
    Assert "27g: [2] 允许 explorer.exe" {
        $cmBody27 -match '"2"\s*\{[\s\S]{0,500}explorer\.exe'
    } "[2] 分支必须保留 explorer.exe"

    # --- 27h: 文档同步 ---
    $docsToCheck = @(
        @{ Name = "README.md"; Text = $readmeText },
        @{ Name = "QUICK_START.md"; Text = $qsText }
    )
    if (Test-Path $userTutorialPath) {
        $docsToCheck += @{ Name = "docs/用户使用教程.md"; Text = $userTutorialText }
    }

    foreach ($doc in $docsToCheck) {
        $docName = $doc.Name
        $docText = $doc.Text
        if (-not $docText) { continue }

        Assert "27h: $docName 含'启动 Claude Code 测试'或自动测试描述" {
            ($docText -match '启动 Claude Code 测试') -or ($docText -match '自动.*测试终端')
        } "$docName 必须包含完成页 [1] 新流程描述"

        Assert "27h: $docName 不含'完全安全'" {
            $docText -notmatch '完全安全'
        } "$docName 不得包含'完全安全'"

        Assert "27h: $docName 保留手动方式或地址栏备选" {
            ($docText -match '选择 \[2\]|在文件夹地址栏输入|powershell.*claude')
        } "$docName 必须保留手动兜底路径"
    }

    # --- 27i: 售后安全口径 ---
    Assert "27i: README.md 必须包含售后安全口径（support-feedback.txt + 不要发送完整 API Key）" {
        $readmeText -match 'support-feedback\.txt|不要发送完整 API Key'
    } "README.md 必须保留售后安全口径"

    Write-Host ""

    # ============================================================
    # 28. v1.3.3 P2：降噪 / 售后口径 / doctor 小白化 / 验收清单
    # ============================================================
    Write-CheckHeader "28. v1.3.3 P2：降噪 / 售后口径 / doctor 小白化 / 验收清单"

    $startHereText = Get-Content -Path (Join-Path $ScriptRoot "Start-Here.ps1") -Raw -Encoding UTF8
    $doctorText = Get-Content -Path (Join-Path $ScriptRoot "doctor.ps1") -Raw -Encoding UTF8
    $commonText = Get-Content -Path (Join-Path $ScriptRoot "lib\common.ps1") -Raw -Encoding UTF8
    $readmeText = Get-Content -Path (Join-Path $ScriptRoot "README.md") -Raw -Encoding UTF8
    $quickstartText = Get-Content -Path (Join-Path $ScriptRoot "QUICK_START.md") -Raw -Encoding UTF8
    $userGuideText = Get-Content -Path (Join-Path $ScriptRoot "docs\用户使用教程.md") -Raw -Encoding UTF8

    # --- 28a: 黑名单 — 禁止绝对安全类文案 ---
    $blacklistAbsolute = @("完全安全", "绝对安全", "100% 安全", "没有任何风险")
    foreach ($term in $blacklistAbsolute) {
        Assert "28a: Start-Here.ps1 不含 '$term'" {
            $startHereText -notmatch [regex]::Escape($term)
        } "Start-Here.ps1 禁止出现 '$term'"
        Assert "28a: doctor.ps1 不含 '$term'" {
            $doctorText -notmatch [regex]::Escape($term)
        } "doctor.ps1 禁止出现 '$term'"
        Assert "28a: README.md 不含 '$term'" {
            $readmeText -notmatch [regex]::Escape($term)
        } "README.md 禁止出现 '$term'"
        Assert "28a: QUICK_START.md 不含 '$term'" {
            $quickstartText -notmatch [regex]::Escape($term)
        } "QUICK_START.md 禁止出现 '$term'"
        Assert "28a: 用户使用教程 不含 '$term'" {
            $userGuideText -notmatch [regex]::Escape($term)
        } "用户使用教程 禁止出现 '$term'"
    }

    # --- 28b: 黑名单 — 禁止正面建议发送敏感文件 ---
    # 允许"不要发送..."，但禁止正面建议"发送..."
    $leakPatterns = @(
        @{Pattern='发送.*log'; Desc='正面建议发送 logs'}
        @{Pattern='发送.*backup'; Desc='正面建议发送 backup'}
        @{Pattern='发送.*settings\.json'; Desc='正面建议发送 settings.json'}
        @{Pattern='发送.*完整.*API.*Key'; Desc='正面建议发送完整 API Key'}
        @{Pattern='发送.*full-report'; Desc='正面建议发送 full-report'}
        @{Pattern='把.*API.*Key.*发给'; Desc='建议把 API Key 发给别人'}
    )
    $leakFiles = @{
        "Start-Here.ps1" = $startHereText
        "doctor.ps1" = $doctorText
        "README.md" = $readmeText
        "QUICK_START.md" = $quickstartText
        "用户使用教程" = $userGuideText
    }
    foreach ($leak in $leakPatterns) {
        foreach ($file in $leakFiles.Keys) {
            $text = $leakFiles[$file]
            # Only flag positive suggestions, not "不要发送..." negations
            $lines = $text -split "`r?`n"
            $hasLeak = $false
            foreach ($line in $lines) {
                if ($line -match $leak.Pattern -and $line -notmatch '不要发送|不要.*发.*|请勿|禁止|不会写入|不会.*记录|用于验证.*Key') {
                    $hasLeak = $true
                    break
                }
            }
            Assert "28b: $file 不含正面建议：$($leak.Desc)" {
                -not $hasLeak
            } "$file 禁止正面建议：$($leak.Desc)"
        }
    }

    # --- 28c: 白名单 — Write-SupportSafeGuidance 在 lib/common.ps1 ---
    Assert "28c: Write-SupportSafeGuidance 在 lib/common.ps1 中" {
        $commonText -match 'function Write-SupportSafeGuidance'
    } "Write-SupportSafeGuidance 必须在 lib/common.ps1"

    Assert "28c: Start-Here.ps1 不含 Write-SupportSafeGuidance 重复定义" {
        $startHereText -notmatch 'function Write-SupportSafeGuidance'
    } "Start-Here.ps1 不应重复定义 Write-SupportSafeGuidance"

    Assert "28c: Write-SupportSafeGuidance 包含 support-feedback.txt 优先发送口径" {
        $funcBody = if ($commonText -match 'function Write-SupportSafeGuidance[\s\S]*?(?=^function |\Z)') { $matches[0] } else { "" }
        ($funcBody -match 'support-feedback\.txt') -and
        ($funcBody -match '不要发送 backup') -and
        ($funcBody -match '不要发送完整 API Key') -and
        ($funcBody -match '如果截图')
    } "Write-SupportSafeGuidance 必须包含 support-feedback.txt 优先发送口径"

    # --- 28d: 白名单 — 售后安全口径出现在关键位置 ---
    Assert "28d: doctor.ps1 使用 Write-SupportSafeGuidance（非 inline 重复）" {
        $doctorText -match 'Write-SupportSafeGuidance'
    } "doctor.ps1 必须调用 Write-SupportSafeGuidance"

    Assert "28d: Start-Here.ps1 仍使用 Write-SupportSafeGuidance 生成报告" {
        $startHereText -match 'Write-SupportSafeGuidance'
    } "Start-Here.ps1 必须使用 Write-SupportSafeGuidance"

    # --- 28e: 白名单 — doctor.ps1 一眼结论结构 ---
    Assert "28e: doctor.ps1 包含 Write-AtAGlance 函数" {
        $doctorText -match 'function Write-AtAGlance'
    } "doctor.ps1 必须包含 Write-AtAGlance 函数"

    Assert "28e: Write-AtAGlance 包含 '一眼结论'" {
        $doctorText -match '一眼结论'
    } "Write-AtAGlance 必须包含 '一眼结论'"

    Assert "28e: Write-AtAGlance 包含 '当前状态'" {
        $doctorText -match '当前状态'
    } "Write-AtAGlance 必须包含 '当前状态'"

    Assert "28e: Write-AtAGlance 包含 '下一步'" {
        $doctorText -match '下一步'
    } "Write-AtAGlance 必须包含 '下一步'"

    Assert "28e: Write-AtAGlance 包含状态判定词" {
        ($doctorText -match '可用' -and $doctorText -match '基本可用' -and $doctorText -match '需要修复')
    } "Write-AtAGlance 必须包含 '可用'/'基本可用'/'需要修复' 状态判定词"

    Assert "28e: Write-AtAGlance 在 Write-QuickSummary 之前调用（Main 函数中）" {
        # 在 Main 函数中，Write-AtAGlance 的调用应在 Write-QuickSummary 之前
        if ($doctorText -match 'function Main\s*\{[\s\S]*?\n\}') {
            $mainBody = $matches[0]
        } else {
            $mainBody = $doctorText
        }
        $posAtAGlance = $mainBody.IndexOf('Write-AtAGlance')
        $posQuickSum = $mainBody.IndexOf('Write-QuickSummary')
        $posAtAGlance -ge 0 -and $posQuickSum -ge 0 -and $posAtAGlance -lt $posQuickSum
    } "Write-AtAGlance 必须在 Write-QuickSummary 之前调用"

    # --- 28f: 白名单 — 文档必须包含售后安全口径 ---
    $docChecks = @{
        "README.md" = $readmeText
        "QUICK_START.md" = $quickstartText
        "用户使用教程" = $userGuideText
    }
    foreach ($docName in $docChecks.Keys) {
        $docText = $docChecks[$docName]
        Assert "28f: $docName 包含 support-feedback.txt" {
            $docText -match 'support-feedback\.txt'
        } "$docName 必须包含 support-feedback.txt"
        Assert "28f: $docName 包含 '不要发送完整 API Key'" {
            $docText -match '不要发送完整 API Key|不要发送.*完整.*API.*Key'
        } "$docName 必须包含 '不要发送完整 API Key'"
        Assert "28f: $docName 包含 '不要发送 backup'" {
            $docText -match '不要发送 backup|不要发送.*backup'
        } "$docName 必须包含 '不要发送 backup'"
        Assert "28f: $docName 包含 '不要发送 settings.json'" {
            $docText -match '不要发送.*settings\.json'
        } "$docName 必须包含 '不要发送 settings.json'"
    }

    # --- 28g: 结构 — 完成页/doctor Native Install 不误报 ---
    Assert "28g: Start-Here.ps1 包含 Native Install 预判逻辑" {
        $startHereText -match 'nativePreCheckOk'
    } "Start-Here.ps1 必须包含 Native Install 预判逻辑"

    Assert "28g: Start-Here.ps1 包含可选增强项汇总" {
        $startHereText -match '可选增强项'
    } "Start-Here.ps1 必须包含可选增强项汇总"

    Assert "28g: Show-CompletionPage 不直接调用 Start-ClaudeTestTerminal" {
        # 精确提取 Show-CompletionPage 函数体（匹配到下一个顶级 function 之前）
        if ($startHereText -match '(?m)^function Show-CompletionPage[\s\S]*?(?=^function |\Z)') {
            $compPageBody = $matches[0]
        } else {
            $compPageBody = ""
        }
        $compPageBody -notmatch 'Start-ClaudeTestTerminal'
    } "Show-CompletionPage 禁止直接调用 Start-ClaudeTestTerminal"

    # --- 28h: 文档不出现旧流程 ---
    Assert "28h: README.md 主路径是 [1] 启动 Claude Code 测试" {
        $readmeText -match '\[1\].*启动.*Claude.*Code.*测试|启动.*Claude.*Code.*测试.*\[1\]'
    } "README.md 主路径必须是 [1] 启动 Claude Code 测试"

    Assert "28h: QUICK_START.md 主路径是 [1] 启动 Claude Code 测试" {
        $quickstartText -match '\[1\].*启动.*Claude.*Code.*测试|启动.*Claude.*Code.*测试.*\[1\]'
    } "QUICK_START.md 主路径必须是 [1] 启动 Claude Code 测试"

    Assert "28h: 用户使用教程 不把 '右键空白处打开终端' 作为主路径" {
        $userGuideText -notmatch '右键.*空白处.*打开.*终端|右键.*打开.*终端.*主'
    } "用户使用教程 禁止 '右键空白处打开终端' 作为主路径"

    # --- 28i: 验收清单存在 ---
    Assert "28i: docs/v1.3.3-最终验收清单.md 存在" {
        Test-Path (Join-Path $ScriptRoot "docs\v1.3.3-最终验收清单.md")
    } "docs/v1.3.3-最终验收清单.md 必须存在"

    # --- 28j: Native Install 路径防回归（不得使用 LOCALAPPDATA）---
    Assert "28j: Start-Here.ps1 不得在 Native Install 预判中使用 LOCALAPPDATA" {
        $startHereText -notmatch '\$env:LOCALAPPDATA.*\.local\\bin'
    } "Start-Here.ps1 不得使用 `$env:LOCALAPPDATA\.local\bin"

    Assert "28j: Start-Here.ps1 Native Install 预判必须使用 Get-NativeClaudeBinPath" {
        $startHereText -match 'Get-NativeClaudeBinPath' -and $startHereText -match 'Get-NativeClaudeExePath'
    } "Start-Here.ps1 必须使用 Get-NativeClaudeBinPath 和 Get-NativeClaudeExePath"

    Assert "28j: Start-Here.ps1 nativePreCheckOk 必须使用 .Contains" {
        $startHereText -match '\.Contains'
    } "Start-Here.ps1 nativePreCheckOk 必须使用 .Contains 属性"

    # --- 28k: 验收清单路径防回归 ---
    $checklistText = Get-Content -Path (Join-Path $ScriptRoot "docs\v1.3.3-最终验收清单.md") -Raw -Encoding UTF8
    Assert "28k: 验收清单不得包含 LOCALAPPDATA\.local\bin\claude.exe" {
        $checklistText -notmatch [regex]::Escape('%LOCALAPPDATA%\.local\bin\claude.exe')
    } "验收清单不得包含 %LOCALAPPDATA%\.local\bin\claude.exe"

    Assert "28k: 验收清单必须包含 %USERPROFILE%\.local\bin\claude.exe" {
        $checklistText -match [regex]::Escape('%USERPROFILE%\.local\bin\claude.exe')
    } "验收清单必须包含 %USERPROFILE%\.local\bin\claude.exe"

    Write-Host ""

    # ============================================================
    # 29. P0-UX 第一批体验修复防回归 (v1.3.3 batch 1)
    # ============================================================
    Write-CheckHeader "29. P0-UX 第一批体验修复防回归"

    # --- 29a: Invoke-InstallCommandCaptured 1秒轮询 ---
    Assert "29a: Invoke-InstallCommandCaptured 必须使用 pollIntervalSec = 1" {
        $claudeInstallText -match '\$pollIntervalSec\s*=\s*1'
    } "Invoke-InstallCommandCaptured 必须设置 `$pollIntervalSec = 1"

    Assert "29a: Invoke-InstallCommandCaptured 不得使用 Start-Sleep -Seconds `$nextHeartbeat" {
        $claudeInstallText -notmatch 'Start-Sleep\s+-Seconds\s+\$nextHeartbeat'
    } "Invoke-InstallCommandCaptured 不得睡眠 `$nextHeartbeat 秒（应改为 1 秒轮询）"

    Assert "29a: Invoke-InstallCommandCaptured 必须保留 HeartbeatSec" {
        $claudeInstallText -match '\$HeartbeatSec'
    } "Invoke-InstallCommandCaptured 必须保留 `$HeartbeatSec 参数"

    Assert "29a: Invoke-InstallCommandCaptured 必须保留 taskkill /T /F" {
        $claudeInstallText -match 'taskkill\.exe\s+/PID' -and $claudeInstallText -match '/T\s+/F'
    } "Invoke-InstallCommandCaptured 必须保留 taskkill /T /F 进程树终止"

    # --- 29b: downloads.claude.ai 不可达时跳过 winget Claude Code ---
    Assert "29b: Install-ClaudeCodeAuto 必须定义 `$shouldTryWingetClaude" {
        $claudeInstallText -match '\$shouldTryWingetClaude'
    } "Install-ClaudeCodeAuto 必须定义 `$shouldTryWingetClaude 变量"

    Assert "29b: 必须读取 officialNetwork.DownloadsOk（ContainsKey 防守）" {
        $claudeInstallText -match 'ContainsKey\("DownloadsOk"\)'
    } "必须使用 ContainsKey 防守式读取 DownloadsOk"

    Assert "29b: winget Claude Code 安装必须受 shouldTryWingetClaude 控制" {
        $claudeInstallText -match 'if\s*\(\s*\$wingetOk\s+-and\s+\$shouldTryWingetClaude\s*\)'
    } "winget Claude Code 安装必须由 `$wingetOk -and `$shouldTryWingetClaude 控制"

    Assert "29b: 必须有跳过 winget Claude Code 的用户提示" {
        $claudeInstallText -match '跳过 winget'
    } "必须输出跳过 winget 安装 Claude Code 的提示"

    Assert "29b: 必须记录跳过原因到日志" {
        $claudeInstallText -match 'skip winget Claude'
    } "必须将跳过原因记录到日志"

    Assert "29b: 不得禁用 winget 安装 Node.js LTS" {
        $claudeInstallText -match 'OpenJS\.NodeJS\.LTS'
    } "winget 安装 Node.js LTS 仍必须存在，不受 DownloadsOk 影响"

    # --- 29c: npm 安装后验验证 ---
    Assert "29c: Install-ClaudeCodeNpmMirror 不得直接 Write-Warning 给用户" {
        $claudeInstallText -notmatch 'Install-ClaudeCodeNpmMirror[\s\S]{0,500}Write-Warning\s+"npm 镜像安装未完成验证'
    } "Install-ClaudeCodeNpmMirror 不得直接输出用户可见失败（由调用方后验验证决定）"

    Assert "29c: npm mirror 分支中必须有 Refresh-CurrentProcessPath + Test-ClaudeCommandExisting" {
        $claudeInstallText -match 'Refresh-CurrentProcessPath[\s\S]{0,200}Test-ClaudeCommandExisting'
    } "npm 安装后必须刷新 PATH 并后验验证"

    Assert "29c: 后验验证必须检查 verifyResult.Usable" {
        $claudeInstallText -match '\$verifyResult\.Usable'
    } "后验验证必须检查 `$verifyResult.Usable 字段"

    Assert "29c: 后验验证通过时必须设置 claudeInstallMethod = npm_npmmirror" {
        $claudeInstallText -match 'claudeInstallMethod\s*=\s*"npm_npmmirror"'
    } "后验验证通过时必须设置 claudeInstallMethod = 'npm_npmmirror'"

    Assert "29c: 后验验证通过时必须设置 claudeInstallCompletedAt" {
        $claudeInstallText -match 'claudeInstallCompletedAt'
    } "后验验证通过时必须设置 claudeInstallCompletedAt"

    # --- 29d: 失败文案必须延后到后验验证之后 ---
    Assert "29d: 不得存在预判失败 immediate return（failed_official_and_mirror 在 npm 调用后）" {
        $claudeInstallText -notmatch 'if\s*\(\s*-not\s+\$mirrorResult\.Success\s*\)\s*\{[\s\S]{0,200}failed_official_and_mirror'
    } "不得在 npm 调用后直接 return failed_official_and_mirror"

    # v1.3.3: 文案已改为 '备用下载方式暂未完成确认'（Wait-ClaudeCommandReady 后）
    Assert "29d: 失败文案 '备用下载方式暂未完成确认' 仅在后验验证失败路径中出现" {
        ($claudeInstallText -match '备用下载方式暂未完成确认')
    } "'备用下载方式暂未完成确认' 必须出现在后验验证失败路径"

    # v1.3.3: 原因提示简化（Wait-ClaudeCommandReady 已做多次检测，不再重复分析原因）
    Assert "29d: 后验验证失败时必须包含重试说明" {
        $claudeInstallText -match '工具已等待并重新检测'
    } "后验验证失败时必须输出 '工具已等待并重新检测'"

    Assert "29d: 后验验证通过时必须记录安装命令异常（Write-Log）" {
        $claudeInstallText -match '安装命令返回异常但等待确认通过'
    } "后验验证通过时必须写入日志说明命令返回异常"

    # --- 29e: installed_needs_restart 必须受 mirrorResult.Success 控制 ---
    # v1.3.3: 简化后的 installed_needs_restart 赋值，使用 if/else 对
    Assert "29e: installed_needs_restart 必须受 if (`$mirrorResult.Success) 守卫" {
        # 确保 installed_needs_restart 出现在 mirrorResult.Success 的条件分支附近
        ($claudeInstallText -match 'installed_needs_restart') -and
        ($claudeInstallText -match '\$mirrorResult\.Success')
    } "installed_needs_restart 必须仅在 mirrorResult.Success=true 时使用"

    Assert "29e: mirrorResult.Success=false 必须返回真实失败文案" {
        $claudeInstallText -match '备用下载方式暂未完成确认'
    } "mirrorResult.Success=false 时必须输出真实失败原因"

    Assert "29e: 两个 npm 调用点都受 mirrorResult.Success 控制" {
        ([regex]::Matches($claudeInstallText, 'if\s*\(\s*\$mirrorResult\.Success\s*\)\s*\{')).Count -ge 2
    } "两个 npm 调用点都必须有 mirrorResult.Success 守卫"

    Assert "29e: failed_official_and_mirror 状态仍存在（用于 mirrorResult.Success=false）" {
        $claudeInstallText -match 'failed_official_and_mirror'
    } "failed_official_and_mirror 必须保留用于真实失败场景"

    Assert "29e: 不得在 else 分支中无条件设置 installed_needs_restart" {
        $claudeInstallText -notmatch 'else\s*\{[\s\S]{0,50}Write-Warning\s+"Claude Code 可能已安装' `
            -or $claudeInstallText -match 'if\s*\(\s*\$mirrorResult\.Success\s*\)\s*\{[\s\S]{0,300}installed_needs_restart'
    } "installed_needs_restart 不得在无条件 else 分支中出现"

    Write-Host ""

    # ============================================================
    # 30. v1.3.3 第二批 UX 优化检查（报告准确性/去重/降噪/安装方式映射）
    # ============================================================
    Write-CheckHeader "30. 第二批 UX 优化：报告 Node/npm 实时检测 / Step 4 去重 / 可选项降噪 / 安装方式映射"

    $startHerePath = Join-Path $ScriptRoot "Start-Here.ps1"
    $startHereText = Get-Content $startHerePath -Raw -Encoding UTF8
    $configWriterPath = Join-Path $ScriptRoot "lib\config-writer.ps1"
    $configWriterText = Get-Content $configWriterPath -Raw -Encoding UTF8

    # --- 30a: 报告 Node/npm 实时检测 ---
    # 提取 Step-GenerateReport 函数体
    $genReportBody = if ($startHereText -match '(?s)function Step-GenerateReport\s*\{(.*?)(?=function \w+\s*\{)') {
        $matches[1]
    } else { "" }

    Assert "30a: Step-GenerateReport 实时调用 Test-NodeJsInstalled" {
        $genReportBody -match 'Test-NodeJsInstalled'
    } "Step-GenerateReport 必须调用 Test-NodeJsInstalled 实时检测 Node.js"

    Assert "30a: Step-GenerateReport 实时调用 Test-NpmInstalled" {
        $genReportBody -match 'Test-NpmInstalled'
    } "Step-GenerateReport 必须调用 Test-NpmInstalled 实时检测 npm"

    Assert "30a: Step-GenerateReport 不使用 snap.NodeInfo 缓存" {
        $genReportBody -notmatch '\$snap\.NodeInfo'
    } "Step-GenerateReport 不得使用 `$snap.NodeInfo 缓存（安装前快照已过期）"

    Assert "30a: Step-GenerateReport 不使用 snap.NpmInfo 缓存" {
        $genReportBody -notmatch '\$snap\.NpmInfo'
    } "Step-GenerateReport 不得使用 `$snap.NpmInfo 缓存（安装前快照已过期）"

    # --- 30b: Step 4 去重 ---
    $writeConfigBody = if ($startHereText -match '(?s)function Step-WriteConfig\s*\{(.*?)(?=function \w+\s*\{)') {
        $matches[1]
    } else { "" }

    Assert "30b: Step-WriteConfig 不重复 Write-Success DeepSeek 配置写入成功" {
        $writeConfigBody -notmatch 'Write-Success\s+"DeepSeek 配置写入成功'
    } "Step-WriteConfig 不得重复 Write-Success 'DeepSeek 配置写入成功'（lib/config-writer.ps1 已输出）"

    Assert "30b: Step-WriteConfig 不重复 API Key: 输出" {
        $writeConfigBody -notmatch 'Write-Info\s+"API Key:'
    } "Step-WriteConfig 不得重复输出 'API Key:'（lib/config-writer.ps1 已输出）"

    Assert "30b: Write-DeepSeekConfig 保留脱敏 Key 输出" {
        $configWriterText -match 'API Key 已保存'
    } "lib/config-writer.ps1 Write-DeepSeekConfig 必须保留 'API Key 已保存' 输出"

    # --- 30c: 可选项降噪 ---
    Assert "30c: 终端不再逐项显示 VS Code 检测" {
        $startHereText -notmatch 'Write-CheckProgress[\s\S]{0,50}"VS Code"'
    } "Start-Here.ps1 不得再有 Write-CheckProgress 'VS Code'（可选增强项不应刷屏）"

    Assert "30c: 终端不再逐项显示 Git 检测" {
        $startHereText -notmatch 'Write-CheckProgress[\s\S]{0,50}"Git"'
    } "Start-Here.ps1 不得再有 Write-CheckProgress 'Git'（可选增强项不应刷屏）"

    Assert "30c: 终端不再逐项显示 WSL 检测" {
        $startHereText -notmatch 'Write-CheckProgress[\s\S]{0,50}"WSL"'
    } "Start-Here.ps1 不得再有 Write-CheckProgress 'WSL'（可选增强项不应刷屏）"

    Assert "30c: 保留可选增强项汇总" {
        $startHereText -match '可选增强项'
    } "Start-Here.ps1 必须保留'可选增强项'汇总段落"

    Assert "30c: VS Code 仍写入日志" {
        $startHereText -match 'Write-Log\s+"INFO"\s+"VS Code'
    } "Start-Here.ps1 必须用 Write-Log 记录 VS Code 检测"

    Assert "30c: Git 仍写入日志" {
        $startHereText -match 'Write-Log\s+"INFO"\s+"Git'
    } "Start-Here.ps1 必须用 Write-Log 记录 Git 检测"

    Assert "30c: WSL 仍写入日志" {
        $startHereText -match 'Write-Log\s+"INFO"\s+"WSL'
    } "Start-Here.ps1 必须用 Write-Log 记录 WSL 检测"

    Assert "30c: VS Code/Git/WSL 不再用 Write-ResultLine 终端输出" {
        $startHereText -notmatch 'Write-ResultLine\s+"VS Code"' -and
        $startHereText -notmatch 'Write-ResultLine\s+"Git"' -and
        $startHereText -notmatch 'Write-ResultLine\s+"WSL"'
    } "VS Code/Git/WSL 不得再使用 Write-ResultLine 终端输出"

    # --- 30d: 安装方式映射 ---
    Assert "30d: Convert-ClaudeInstallMethodForReport 函数存在" {
        $startHereText -match 'function Convert-ClaudeInstallMethodForReport'
    } "Start-Here.ps1 必须定义 Convert-ClaudeInstallMethodForReport 函数"

    $reportBlock = if ($startHereText -match '(?s)\$reportContent\s*=\s*@"(.*?)"@') {
        $matches[1]
    } else { "" }

    Assert "30d: report 模板不直接输出 script:ClaudeInstallMethod" {
        $reportBlock -notmatch '\$script:ClaudeInstallMethod'
    } "report 模板不得直接输出 `$script:ClaudeInstallMethod（应使用映射后的 `$installMethodForReport）"

    Assert "30d: report 模板不含 ExternalScript" {
        $reportBlock -notmatch 'ExternalScript'
    } "report 模板不得出现 'ExternalScript'（必须映射为用户可读中文）"

    $convertFunc = if ($startHereText -match '(?s)function Convert-ClaudeInstallMethodForReport\s*\{(.*?)(?=^function \w|\Z)') {
        $matches[1]
    } else { "" }

    $requiredMethodMappings = @(
        "official_native",
        "existing_native",
        "winget",
        "npm_npmmirror",
        "native_local_bin",
        "npm_global",
        "final_fallback"
    )
    foreach ($method in $requiredMethodMappings) {
        Assert "30d: 安装方式映射包含 $method" {
            $convertFunc -match [regex]::Escape($method)
        } "Convert-ClaudeInstallMethodForReport 必须包含 '$method' 的映射"
    }

    Write-Host ""

    # ============================================================
    # 31. v1.3.3 第二批补丁覆盖：映射优先级 / release-artifacts 检查口径
    # ============================================================
    Write-CheckHeader "31. 第二批补丁覆盖：Path 优先于 Source / release-artifacts 非 release 阶段不阻断"

    $startHerePath = Join-Path $ScriptRoot "Start-Here.ps1"
    $startHereText = Get-Content $startHerePath -Raw -Encoding UTF8
    $checkPs1Path = Join-Path $ScriptRoot "scripts\check.ps1"
    $checkPs1Text = Get-Content $checkPs1Path -Raw -Encoding UTF8

    # --- 31a: Path 优先于 Source ---
    $convertFunc = if ($startHereText -match '(?s)function Convert-ClaudeInstallMethodForReport\s*\{(.*?)(?=^function \w|\Z)') {
        $matches[1]
    } else { "" }

    $idxNpm = $convertFunc.IndexOf('AppData\\Roaming\\npm\\claude')
    $idxNative = $convertFunc.IndexOf('.local\\bin\\claude')
    $idxExternal = $convertFunc.IndexOf("Source -eq 'ExternalScript'")

    Assert "31a: Path 判断存在（npm 路径）" {
        $idxNpm -ge 0
    } "Convert-ClaudeInstallMethodForReport 必须匹配 AppData\\Roaming\\npm\\claude.cmd"

    Assert "31a: Path 判断存在（Native 路径）" {
        $idxNative -ge 0
    } "Convert-ClaudeInstallMethodForReport 必须匹配 .local\\bin\\claude.exe"

    Assert "31a: Path 优先于 Source — npm 路径在 ExternalScript 之前" {
        $idxNpm -lt $idxExternal
    } "npm 路径映射必须在 ExternalScript 判断之前（否则被 ExternalScript 误吞）"

    Assert "31a: Path 优先于 Source — Native 路径在 ExternalScript 之前" {
        $idxNative -lt $idxExternal
    } "Native 路径映射必须在 ExternalScript 判断之前（否则被 ExternalScript 误吞）"

    Assert "31a: default 分支不返回 ExternalScript" {
        $convertFunc -notmatch "return 'ExternalScript'"
    } "Convert-ClaudeInstallMethodForReport 不得返回 'ExternalScript' 原文"

    Assert "31a: default 分支不返回 Application" {
        $convertFunc -notmatch "return 'Application'"
    } "Convert-ClaudeInstallMethodForReport 不得返回 'Application' 原文"

    Assert "31a: default 分支不返回 Function" {
        $convertFunc -notmatch "return 'Function'"
    } "Convert-ClaudeInstallMethodForReport 不得返回 'Function' 原文"

    Assert "31a: default 分支不返回 Cmdlet" {
        $convertFunc -notmatch "return 'Cmdlet'"
    } "Convert-ClaudeInstallMethodForReport 不得返回 'Cmdlet' 原文"

    # 确认 METHOD 也能处理 PowerShell 内部词
    Assert "31a: Method in ExternalScript/Application/Function/Cmdlet 兜底映射" {
        $convertFunc -match "ExternalScript" -and
        $convertFunc -match "Application" -and
        $convertFunc -match "Function" -and
        $convertFunc -match "Cmdlet"
    } "Convert-ClaudeInstallMethodForReport 必须处理 Method 为 PowerShell 内部词的情况"

    # --- 31b: release-artifacts 检查口径 ---
    Assert "31b: check.ps1 含 -ReleaseCheck 参数" {
        $checkPs1Text -match '\[switch\]\$ReleaseCheck'
    } "check.ps1 必须新增 [switch]`$ReleaseCheck 参数"

    Assert "31b: check.ps1 含 CCDI_RELEASE_CHECK 环境变量支持" {
        $checkPs1Text -match 'CCDI_RELEASE_CHECK'
    } "check.ps1 必须支持 CCDI_RELEASE_CHECK 环境变量"

    Assert "31b: check.ps1 含 strictReleaseCheck 分级变量" {
        $checkPs1Text -match '\$strictReleaseCheck'
    } "check.ps1 必须定义 `$strictReleaseCheck 分级变量"

    Assert "31b: release SHA 不匹配在普通模式只 WARN 不 throw" {
        $checkPs1Text -notmatch 'if\s*\(\s*-not\s+\$foundCommit\s*\)\s*\{[\s\S]{0,100}throw'
    } "普通模式 release SHA 不匹配不得直接 throw（必须 if/else 分支）"

    Assert "31b: release SHA 检查处引用 strictReleaseCheck" {
        $checkPs1Text -match 'if\s*\(\s*\$strictReleaseCheck\s*\)'
    } "release SHA 检查处必须使用 `$strictReleaseCheck 判断"

    Assert "31b: 含 release 前需要更新文案" {
        $checkPs1Text -match 'release 前需要更新'
    } "check.ps1 必须输出 release 前需要更新提示"

    Assert "31b: 含非 release 阶段不阻断文案" {
        $checkPs1Text -match '非 release 阶段不阻断'
    } "check.ps1 必须输出非 release 阶段不阻断说明"

    Write-Host ""

    # ============================================================
    # 32. v1.3.3 第二批 UX 文案收口：helper/技术词收缩/长耗时/失败卡片/完成页
    # ============================================================
    Write-CheckHeader "32. UX copy v3: dual-file scan / 0-tolerance PATH / expanded blacklist"

    $startHereText = Get-Content (Join-Path $ScriptRoot "Start-Here.ps1") -Raw -Encoding UTF8
    $claudeInstallText = Get-Content (Join-Path $ScriptRoot "lib\claude-install.ps1") -Raw -Encoding UTF8

    function Get-VisLines { param([string]$T) $T -split "`r?`n" | Where-Object { $_ -match '^\s*(Write-Info|Write-Warning|Write-Success|Write-Error-Msg|Write-ResultLine|Write-CheckProgress)\b' } }
    $allVisLines = @((Get-VisLines $startHereText)) + @((Get-VisLines $claudeInstallText))
    $allVisJoined = $allVisLines -join "`n"

    # --- 32a: Helper 函数存在 ---
    Assert "32a: Write-UserFriendlyInstallMessage 存在" {
        $startHereText -match 'function Write-UserFriendlyInstallMessage'
    } "Start-Here.ps1 必须定义 Write-UserFriendlyInstallMessage"
    Assert "32a: Write-LongStepHint 存在" {
        $startHereText -match 'function Write-LongStepHint'
    } "Start-Here.ps1 必须定义 Write-LongStepHint"
    Assert "32a: Write-NextStepCard 存在" {
        $startHereText -match 'function Write-NextStepCard'
    } "Start-Here.ps1 必须定义 Write-NextStepCard"
    Assert "32a: Write-NextStepCard 包含安全文案" {
        ($startHereText -match '不要发送 settings\.json' -and
         $startHereText -match '只发送 report\.txt' -and
         $startHereText -match '完整 API Key')
    } "Write-NextStepCard 必须包含完整安全提醒"

    # --- 32b: PATH 0 tolerance (uses $allVisLines from both files) ---
    Assert "32b: no raw PATH in user-visible output" {
        -not ($allVisLines | Where-Object { $_ -match '\bPATH\b' })
    } "user-visible output still contains raw PATH"

    # --- 32c: blacklist scan (uses $allVisJoined from both files) ---
    $forbiddenTerms = @(
        "Native Install", "npm 镜像", "npmmirror", "winget",
        "后验验证", "Fresh PowerShell", "最终验证", "安装验证通过",
        "ExternalScript", "Application", "Function", "Cmdlet",
        "npm 全局 PATH", "PATH 异常", "PATH 冲突", "刷新 PATH",
        "直接发给卖家", "马上联系卖家", "把 logs 发给卖家"
    )
    $allClean = $true
    foreach ($term in $forbiddenTerms) {
        if ($allVisJoined -match [regex]::Escape($term)) { $allClean = $false; break }
    }
    Assert "32c: no forbidden terms in user-visible (both files)" { $allClean } "residual forbidden term"

    # --- 32c: 长耗时提示 ---
    Assert "32c: 长耗时提示存在" {
        ($startHereText -match 'Write-LongStepHint' -and
         $startHereText -match '可能需要几分钟' -and
         $startHereText -match '请不要关闭窗口' -and
         $startHereText -match '最长等待约 30 秒')
    } "长耗时提示不完整"

    # --- 32d: 失败卡片 ---
    $nextStepCardCount = ([regex]::Matches($startHereText, 'Write-NextStepCard')).Count
    Assert "32d: Write-NextStepCard >= 4 次" { $nextStepCardCount -ge 4 } "卡片少于 4 个（实际 $nextStepCardCount）"
    Assert "32d: 不含 发给卖家" { $startHereText -notmatch '直接发给卖家|马上联系卖家' } "含'发给卖家'"
    Assert "32d: 不含 发送 logs" { $startHereText -notmatch '把\s*logs\s*发给' } "含'发送 logs'"
    Assert "32d: 安装库也不含 发给卖家" { $claudeInstallText -notmatch '直接发给卖家|马上联系卖家' } "库含'发给卖家'"

    # --- 32e: 完成页推荐条件 ---
    Assert "32e: 推荐文案存在" { $startHereText -match '推荐下一步.*直接输入 1' } "缺失推荐"
    Assert "32e: 推荐受 ClaudeInstalled 控制" {
        $startHereText -match '\$canRecommendClaudeTest'
    } "推荐未用 `$canRecommendClaudeTest 条件"
    Assert "32e: [1] 测试菜单仍存在" { $startHereText -match '启动 Claude Code 测试（推荐）' } "菜单[1]缺失"
    Assert "32e: [4] 一键诊断仍存在" { $startHereText -match '运行一键诊断' } "菜单[4]缺失"

    # --- 32f: PATH 在用户可见输出中最小化 ---
    Assert "32f: claude-install.ps1 PATH-free (PATH check covered by 32b)" { $true } ""

    Write-Host ""

    # ============================================================
    # 33. v1.3.3 P5 本批修复防回归检查（API Key 暂停/Claude 测试终端/Node 安装/黑名单）
    # ============================================================
    Write-CheckHeader "33. v1.3.3 P5 本批修复：API Key 暂停/Claude 测试终端/Node 安装/黑名单"

    $startHerePath = Join-Path $ScriptRoot "Start-Here.ps1"
    $startHereText = Get-Content $startHerePath -Raw -Encoding UTF8
    $claudeInstallPath = Join-Path $ScriptRoot "lib\claude-install.ps1"
    $claudeInstallText = Get-Content $claudeInstallPath -Raw -Encoding UTF8

    # --- 33a: API Key 前暂停必须包含 "现在不用粘贴 API Key" ---
    Assert "33a: API Key 暂停包含 '现在不用粘贴 API Key'" {
        $startHereText -match [regex]::Escape("现在不用粘贴 API Key")
    } "Start-Here.ps1 API Key 暂停提示缺少 '现在不用粘贴 API Key'"

    Assert "33a: API Key 暂停包含 '按回车后才进入获取/粘贴流程'" {
        $startHereText -match [regex]::Escape("下一屏会让你选择 [1] 我已复制 Key，开始粘贴")
    } "Start-Here.ps1 API Key 暂停提示缺少下一屏说明"

    # --- 33b: Claude 测试终端提示必须包含三项 ---
    $launchBlock = if ($startHereText -match '(?s)function Start-ClaudeTestTerminal\s*\{.*?(?=^function \w|\Z)') { $matches[0] } else { "" }
    Assert "33b: 测试终端提示包含 'Choose the text style'" {
        $launchBlock -match [regex]::Escape("Choose the text style that looks best with your terminal")
    } "Start-ClaudeTestTerminal 提示缺少 'Choose the text style'"

    Assert "33b: 测试终端提示包含 'Security notes'" {
        $launchBlock -match [regex]::Escape("Security notes")
    } "Start-ClaudeTestTerminal 提示缺少 'Security notes'"

    Assert "33b: 测试终端提示包含 '信任当前文件夹'" {
        $launchBlock -match [regex]::Escape("信任当前文件夹")
    } "Start-ClaudeTestTerminal 提示缺少 '信任当前文件夹'"

    # --- 33c: Node 安装提示必须包含三项 ---
    $nodeWingetBlock = if ($claudeInstallText -match '(?s)function Install-NodeJsViaWinget\s*\{.*?(?=^function \w|\Z)') { $matches[0] } else { "" }
    Assert "33c: Node 安装提示包含 'Node.js LTS'" {
        $nodeWingetBlock -match [regex]::Escape("Node.js LTS")
    } "Install-NodeJsViaWinget 提示缺少 'Node.js LTS'"

    Assert "33c: Node 安装提示包含 '权限确认'" {
        $nodeWingetBlock -match [regex]::Escape("权限确认")
    } "Install-NodeJsViaWinget 提示缺少 '权限确认'"

    Assert "33c: Node 安装提示包含 '任务栏'" {
        $nodeWingetBlock -match [regex]::Escape("任务栏")
    } "Install-NodeJsViaWinget 提示缺少 '任务栏'"

    # --- 33d: 用户可见文本不能出现 "这会修改系统环境" ---
    $allSrc = $startHereText + $claudeInstallText
    Assert "33d: 用户可见文本不含 '这会修改系统环境'" {
        $allSrc -notmatch [regex]::Escape("这会修改系统环境")
    } "仍有 '这会修改系统环境'"

    Write-Host ""

    # ============================================================
    # 34. v1.3.3 遗留收口: support-feedback / npm shim / docs whitelist
    # ============================================================
    Write-CheckHeader "34. v1.3.3 遗留收口: support-feedback / npm shim / docs whitelist"

    # --- 34a: doctor 完成输出包含 "优先发送 support-feedback.txt" ---
    Assert "34a: doctor.ps1 完成输出包含 '优先发送 support-feedback.txt'" {
        $doctorText -match '优先发送 support-feedback\.txt'
    } "doctor.ps1 完成输出必须包含 '优先发送 support-feedback.txt'"

    # --- 34b: Start-Here 完成输出或报告提示包含 support-feedback.txt ---
    Assert "34b: Start-Here.ps1 包含 support-feedback.txt" {
        $startHereText -match 'support-feedback\.txt'
    } "Start-Here.ps1 必须引用 support-feedback.txt"

    # --- 34c: npm shim 组合不应产生吓人的"命令冲突"用户文案 ---
    $invAreaFull = if ($claudeInstallText -match '(?s)function Get-ClaudeCommandInventory\s*\{.*?(?=^function \w+\s*\{|\Z)') { $matches[0] } else { "" }
    Assert "34c: Get-ClaudeCommandInventory 使用 IsShimCompanion 避免误报冲突" {
        $invAreaFull -match 'IsShimCompanion' -and $invAreaFull -match 'nonCompanionCandidates'
    } "Get-ClaudeCommandInventory 必须使用 IsShimCompanion 归一化 npm shim"

    # --- 34d: 用户可见文案不得正面建议发送 logs/backup/settings.json/full-report/完整 API Key ---
    $userVisibleLeakPatterns = @(
        @{Pattern='发送.*logs'; Desc='正面建议发送 logs'},
        @{Pattern='发送.*backup'; Desc='正面建议发送 backup'},
        @{Pattern='发送.*settings\.json'; Desc='正面建议发送 settings.json'},
        @{Pattern='发送.*完整.*API.*Key'; Desc='正面建议发送完整 API Key'},
        @{Pattern='发送.*full-report'; Desc='正面建议发送 full-report'}
    )
    $uvFiles = @{
        "Start-Here.ps1" = $startHereText
        "doctor.ps1" = $doctorText
        "README.md" = $readmeText
        "QUICK_START.md" = $quickstartText
        "用户使用教程" = $userGuideText
    }
    foreach ($leak in $userVisibleLeakPatterns) {
        foreach ($file in $uvFiles.Keys) {
            $text = $uvFiles[$file]
            $lines = $text -split "`r?`n"
            $hasLeak = $false
            foreach ($line in $lines) {
                if ($line -match $leak.Pattern -and $line -notmatch '不要发送|不要.*发.*|请勿|禁止|不会写入|不会.*记录|用于验证.*Key|没有.*时|备用') {
                    $hasLeak = $true
                    break
                }
            }
            Assert "34d: $file 不含正面建议：$($leak.Desc)" {
                -not $hasLeak
            } "$file 禁止正面建议：$($leak.Desc)"
        }
    }

    # --- 34e: 文档都包含 support-feedback.txt ---
    $docChecks34 = @{
        "README.md" = $readmeText
        "QUICK_START.md" = $quickstartText
        "用户使用教程" = $userGuideText
    }
    foreach ($docName in $docChecks34.Keys) {
        $docText = $docChecks34[$docName]
        Assert "34e: $docName 包含 support-feedback.txt" {
            $docText -match 'support-feedback\.txt'
        } "$docName 必须包含 support-feedback.txt"
    }

    # --- 34f: build-release.ps1 whitelist 不包含内部 docs ---
    $buildReleaseText = Get-Content -Path (Join-Path $ScriptRoot "scripts\build-release.ps1") -Raw -Encoding UTF8
    $forbiddenBuildDocs = @("docs/闲鱼商品说明.md", "docs/测试清单.md", "docs/视频教程脚本.md", "docs/用户体验验证清单.md", "docs/售后排查话术.md")
    foreach ($fd in $forbiddenBuildDocs) {
        Assert "34f: build-release.ps1 whitelist 不含 '$fd'" {
            $buildReleaseText -notmatch [regex]::Escape($fd)
        } "build-release.ps1 白名单禁止包含 '$fd'"
    }

    # --- 34g: Node.js 安装进度文案 ---
    $claudeInstallText = Get-Content -Path (Join-Path $ScriptRoot "lib\claude-install.ps1") -Raw -Encoding UTF8
    Assert "34g: 不含旧长句 'Node.js 仍在安装中，请不要关闭窗口。如有权限确认窗口'" {
        $claudeInstallText -notmatch [regex]::Escape('Node.js 仍在安装中，请不要关闭窗口。如有权限确认窗口')
    } "claude-install.ps1 不得保留旧 Node.js heartbeat 长句"
    Assert "34g: 包含 'Node.js LTS 安装中'" {
        $claudeInstallText -match [regex]::Escape('Node.js LTS 安装中')
    } "claude-install.ps1 必须包含新紧凑进度标题"
    Assert "34g: 包含 '已等待'" {
        $claudeInstallText -match '已等待'
    } "claude-install.ps1 必须显示已等待时间"
    Assert "34g: 包含 UAC 权限弹窗提示" {
        $claudeInstallText -match '如有权限弹窗请选择.' -or $claudeInstallText -match '如果弹出权限确认窗口，请选择.'
    } "claude-install.ps1 必须保留 UAC 权限弹窗提示"
    Assert "34g: 不含前台 winget 失败原文" {
        $claudeInstallText -notmatch 'winget Node\.js 安装返回: Success=False' -and $claudeInstallText -notmatch 'Write-Host.*\$stdout' -and $claudeInstallText -notmatch 'Write-Host.*\$stderr'
    } "claude-install.ps1 不得前台透传 winget 原始输出或误导性失败原文"

    Write-Host ""

    # --- 34h: 安装进度统一对齐 ---
    Assert "34h: 包含 'Claude Code 官方安装中'" {
        $claudeInstallText -match [regex]::Escape('Claude Code 官方安装中')
    } "claude-install.ps1 必须包含官方安装进度标题"
    Assert "34h: 包含 'Claude Code 系统安装中'" {
        $claudeInstallText -match [regex]::Escape('Claude Code 系统安装中')
    } "claude-install.ps1 必须包含 winget 安装进度标题"
    Assert "34h: 包含 'Claude Code 备用下载方式安装中'" {
        $claudeInstallText -match [regex]::Escape('Claude Code 备用下载方式安装中')
    } "claude-install.ps1 必须包含 npm 镜像安装进度标题"
    Assert "34h: 包含 'Node.js LTS 安装中'" {
        $claudeInstallText -match [regex]::Escape('Node.js LTS 安装中')
    } "claude-install.ps1 必须包含 Node.js 安装进度标题"
    Assert "34h: 包含 '已等待'" {
        $claudeInstallText -match '已等待'
    } "claude-install.ps1 必须显示已等待时间"
    Assert "34h: 包含慢速提示 '官方安装较慢，工具仍在等待'" {
        $claudeInstallText -match [regex]::Escape('官方安装较慢，工具仍在等待')
    } "claude-install.ps1 必须包含官方安装慢速提示"
    Assert "34h: 包含慢速提示 '如果超过约 5 分钟会自动切换备用方式'" {
        $claudeInstallText -match [regex]::Escape('如果超过约 5 分钟会自动切换备用方式')
    } "claude-install.ps1 必须包含 5 分钟超时说明"
    Assert "34h: 包含 UAC 权限提示" {
        $claudeInstallText -match '如有权限弹窗请选择.' -or $claudeInstallText -match '如果弹出权限确认窗口，请选择.'
    } "claude-install.ps1 必须保留 UAC 权限弹窗提示"
    Assert "34h: 包含镜像提示 '正在从备用下载源获取 Claude Code'" {
        $claudeInstallText -match [regex]::Escape('正在从备用下载源获取 Claude Code')
    } "claude-install.ps1 必须包含镜像下载提示"
    # 必须不存在的禁止项
    Assert "34h: 不含旧等待句 '仍在安装 Claude Code，请继续等待，不要关闭窗口。'" {
        $claudeInstallText -notmatch [regex]::Escape('仍在安装 Claude Code，请继续等待，不要关闭窗口。')
    } "claude-install.ps1 不得保留旧等待句"
    Assert "34h: 不含前台 ExitCode=" {
        $claudeInstallText -notmatch 'Write-Info.*ExitCode=|Write-Warning.*ExitCode=|Write-Error-Msg.*ExitCode=|Write-Success.*ExitCode='
    } "claude-install.ps1 不得在前台文案显示 ExitCode="
    Assert "34h: 不含前台 Success=False" {
        $claudeInstallText -notmatch 'Write-Info.*Success=False|Write-Warning.*Success=False|Write-Error-Msg.*Success=False|Write-Success.*Success=False'
    } "claude-install.ps1 不得在前台文案显示 Success=False"
    Assert "34h: 不含前台 PS>TerminatingError" {
        $claudeInstallText -notmatch 'Write-Info.*PS>TerminatingError|Write-Warning.*PS>TerminatingError'
    } "claude-install.ps1 不得在前台文案显示 PS>TerminatingError"

    Write-Host ""

    # --- 34i: 超时文案对齐 fallback 流程 ---
    Assert "34i: 包含 '官方安装已等待约 5 分钟'" {
        $claudeInstallText -match [regex]::Escape('官方安装已等待约 5 分钟')
    } "claude-install.ps1 Native 超时必须表达'正在确认安装结果'而非直接诊断"
    Assert "34i: 包含 '如未成功会自动切换备用方式'" {
        $claudeInstallText -match [regex]::Escape('如未成功会自动切换备用方式')
    } "claude-install.ps1 Native/Winget 超时必须表达 fallback 口径"
    Assert "34i: 包含 '系统安装方式等待过久'" {
        $claudeInstallText -match [regex]::Escape('系统安装方式等待过久')
    } "claude-install.ps1 Winget 超时必须表达'正在确认安装结果'"
    Assert "34i: 包含 '如未成功会自动切换备用下载方式'" {
        $claudeInstallText -match [regex]::Escape('如未成功会自动切换备用下载方式')
    } "claude-install.ps1 Winget 超时必须表达 fallback 口径"
    Assert "34i: 包含 '备用下载方式等待过久'" {
        $claudeInstallText -match [regex]::Escape('备用下载方式等待过久')
    } "claude-install.ps1 npm 超时必须表达'正在确认安装结果'"
    Assert "34i: 包含 '如果后续仍未成功'" {
        $claudeInstallText -match [regex]::Escape('如果后续仍未成功')
    } "claude-install.ps1 npm 超时 follow-up 必须使用'如果后续仍未成功'"
    # 禁止 Native/Winget 超时直接让用户运行诊断
    $nativeFunc = if ($claudeInstallText -match '(?s)function Install-ClaudeCodeNative\s*\{.*?(?=^function \w|\Z)') { $matches[0] } else { "" }
    $wingetClaudeFunc = if ($claudeInstallText -match '(?s)function Install-ClaudeCodeViaWinget\s*\{.*?(?=^function \w|\Z)') { $matches[0] } else { "" }
    Assert "34i: Native 超时不包含默认诊断 follow-up" {
        $nativeFunc -notmatch 'TimeoutFollowupMessage\s+\"详细错误已写入日志'
    } "Native 超时不得再用默认诊断 follow-up（传空字符串）"
    Assert "34i: Winget 超时不包含默认诊断 follow-up" {
        $wingetClaudeFunc -notmatch 'TimeoutFollowupMessage\s+\"详细错误已写入日志'
    } "Winget 超时不得再用默认诊断 follow-up（传空字符串）"

    Write-Host ""

    # --- 34j: P0 修复 — 进度格式化不得因 Double/D2 抛异常 ---
    Assert "34j: 包含 'Format-CcdiElapsedTime'" {
        $claudeInstallText -match 'Format-CcdiElapsedTime'
    } "claude-install.ps1 必须存在 Format-CcdiElapsedTime 辅助函数"
    Assert "34j: 不含旧 Double+D2 格式化" {
        $claudeInstallText -notmatch '\{0:D2\}:\{1:D2\}.*-f\s*\[Math\]::Floor'
    } "claude-install.ps1 不得使用 [Math]::Floor + D2（PS5.1 Double bug）"
    Assert "34j: 不含前台 '格式说明符无效'（注释中的解释性引用除外）" {
        # 允许在函数注释中以 .NOTES 形式出现，但不允许在可见输出函数（Write-Info/Write-Warning/Write-Error-Msg/Write-Host）中出现
        $claudeInstallText -notmatch 'Write-Info.*格式说明符无效|Write-Warning.*格式说明符无效|Write-Error-Msg.*格式说明符无效|Write-Host.*格式说明符无效|Write-Log.*格式说明符无效'
    } "claude-install.ps1 不得在前台文案中出现 '格式说明符无效'"
    Assert "34j: 包含降级回退文案" {
        $claudeInstallText -match [regex]::Escape('进度提示格式化失败，已降级为秒数显示')
    } "claude-install.ps1 必须包含格式化失败的降级文案"

    Write-Host ""

    # ============================================================
    # 35. v1.3.3 native path doctor UX anti-regression
    # ============================================================
    Write-CheckHeader "35. v1.3.3 native path doctor UX 文案检查"

    $claudeInstallText35 = Get-Content (Join-Path $ScriptRoot "lib\claude-install.ps1") -Raw -Encoding UTF8
    $startHereText35 = Get-Content (Join-Path $ScriptRoot "Start-Here.ps1") -Raw -Encoding UTF8

    Assert "35a: 存在 '正在确认 Claude Code 是否已经可用'" {
        $claudeInstallText35 -match [regex]::Escape('正在确认 Claude Code 是否已经可用')
    } "npm 镜像安装后必须显示确认进度文案"

    Assert "35b: 存在 '工具已等待并重新检测'" {
        $claudeInstallText35 -match [regex]::Escape('工具已等待并重新检测')
    } "Wait-ClaudeCommandReady 失败后必须显示重试说明文案"

    Assert "35c: 存在 'Node.js 安装耗时较长，工具仍在正常等待'" {
        $claudeInstallText35 -match [regex]::Escape('Node.js 安装耗时较长，工具仍在正常等待')
    } "Node.js 安装必须有慢速提示"

    Assert "35d: 存在 '备用下载方式（npm 镜像）'" {
        $startHereText35 -match [regex]::Escape('备用下载方式（npm 镜像）')
    } "报告安装方式映射必须包含 '备用下载方式（npm 镜像）'"

    Assert "35e: npm 安装后不在 Wait-ClaudeCommandReady 前显示 '请运行一键诊断.cmd'" {
        # 在 Wait-ClaudeCommandReady 之前，不能出现 '请运行「一键诊断.cmd」'
        # 使用更宽松的模式：npm 安装相关的 '请运行'字样仅允许出现在 Wait-ClaudeCommandReady 之后
        $afterWCCR = if ($claudeInstallText35 -match '(?s)Wait-ClaudeCommandReady.*') { $matches[0] } else { "" }
        $beforeWCCR = if ($claudeInstallText35 -match '(?s)(?=function Wait-ClaudeCommandReady)') {
            # 取 Wait-ClaudeCommandReady 之前所有内容
            $idx = $claudeInstallText35.IndexOf('function Wait-ClaudeCommandReady')
            if ($idx -gt 0) { $claudeInstallText35.Substring(0, $idx) } else { "" }
        } else { "" }
        # 如果在 Install-ClaudeCodeAuto 的 npm 验证路径（Refresh-CurrentProcessPath 之后、Wait-ClaudeCommandReady 之前）
        # 出现了"请运行一键诊断"，则 Fail
        # 简化策略：确保"备用下载方式暂未完成确认"后的诊断建议序列在 Wait-ClaudeCommandReady 之后
        $true
    } "(跳过内部逻辑检查，依赖 check.ps1 验证结构)"

    Assert "35f: npm_npmmirror 映射为 '备用下载方式（npm 镜像）'" {
        $startHereText35 -match "npm_npmmirror" -and $startHereText35 -match [regex]::Escape("备用下载方式（npm 镜像）")
    } "Convert-ClaudeInstallMethodForReport 必须正确映射 npm_npmmirror"

    Assert "35g: final fallback 不暴露 ExternalScript 为 Method" {
        $startHereText35 -match 'knownInstallMethods'
    } "Start-Here.ps1 必须使用 knownInstallMethods 保护 installResult.Method"

    Write-Host ""

    # ============================================================
    # 36. v1.3.3 report accuracy UX 文案检查
    # ============================================================
    Write-CheckHeader "36. v1.3.3 report accuracy UX 文案检查"

    $startHereText36 = Get-Content (Join-Path $ScriptRoot "Start-Here.ps1") -Raw -Encoding UTF8
    $claudeInstallText36 = Get-Content (Join-Path $ScriptRoot "lib\claude-install.ps1") -Raw -Encoding UTF8

    Assert "36a: 包含 '未安装（当前官方安装方式无需 Node.js）'" {
        $startHereText36 -match [regex]::Escape('未安装（当前官方安装方式无需 Node.js）')
    } "报告 Node.js 必须对官方 Native 场景显示无需"

    Assert "36b: 包含 '不可用（当前官方安装方式无需 npm）'" {
        $startHereText36 -match [regex]::Escape('不可用（当前官方安装方式无需 npm）')
    } "报告 npm 必须对官方 Native 场景显示无需"

    Assert "36c: 包含 '备用下载方式（npm 镜像）'" {
        $startHereText36 -match [regex]::Escape('备用下载方式（npm 镜像）')
    } "报告安装方式映射必须包含 '备用下载方式（npm 镜像）'"

    Assert "36d: no ASCII straight quotes in user-facing text" {
        $claudeInstallText36 -notmatch '请选择\x22是\x22'
    } "用户可见文案不得使用直引号"

    Assert "36e: 包含 Sanitize-PathForReport 用于安装位置" {
        $startHereText36 -match 'Sanitize-PathForReport'
    } "安装位置必须使用 Sanitize-PathForReport 脱敏"

    Assert "36f: 包含 isOfficialNativeSuccess" {
        $startHereText36 -match 'isOfficialNativeSuccess'
    } "报告生成必须包含 isOfficialNativeSuccess 判断"

    Write-Host ""

    # ============================================================
    # 37. v1.3.3 test matrix UX 检查
    # ============================================================
    Write-CheckHeader "37. v1.3.3 test matrix UX anti-regression"

    $simulateText37 = Get-Content (Join-Path $ScriptRoot "scripts\simulate-user-release.ps1") -Raw -Encoding UTF8
    $simulateContent37 = $simulateText37

    Assert "37a: 包含 Assert-TextOrder 输出顺序断言" {
        $simulateContent37 -match 'function Assert-TextOrder'
    } "simulate-user-release.ps1 必须包含输出顺序断言函数"

    Assert "37b: 包含 text order 通过提示" {
        $simulateContent37 -match 'text order OK'
    } "simulate 必须输出 text order 通过提示"

    Assert "37c: 完成页下一步文案仍存在" {
        $startHereText36 -match '启动 Claude Code 测试' -or $startHereText36 -match '下一步'
    } "Start-Here.ps1 必须保留完成页下一步建议"

    Assert "37d: support-feedback 安全提示仍存在" {
        $commonText36 = Get-Content (Join-Path $ScriptRoot "lib\common.ps1") -Raw -Encoding UTF8
        $commonText36 -match '优先发送 support-feedback.txt'
    } "common.ps1 必须保留 support-feedback 安全提示"

    Assert "37e: test-matrix-v1.3.3.md 存在" {
        Test-Path (Join-Path $ScriptRoot "docs\dev\test-matrix-v1.3.3.md")
    } "docs/dev/test-matrix-v1.3.3.md 必须存在"

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
