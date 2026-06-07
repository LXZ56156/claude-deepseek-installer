# ============================================================
# build-release.ps1 - Release ZIP 打包脚本
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File .\scripts\build-release.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\build-release.ps1 -Version "1.3.1"
#
# 输出:
#   release/ClaudeCode-DeepSeek-本地配置助手-v1.3.0.zip
#   release/ClaudeCode-DeepSeek-本地配置助手-v1.3.0.zip.sha256
# ============================================================

param(
    [string]$Version = "1.3.0",
    [string]$OutputDir = $null,
    [switch]$SkipSha256
)

$ErrorActionPreference = "Stop"

# 确定项目根目录
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $ProjectRoot) {
    $ProjectRoot = Get-Location
}

# 确定输出目录
if (-not $OutputDir) {
    $OutputDir = Join-Path $ProjectRoot "release"
}

$ReleaseName = "ClaudeCode-DeepSeek-本地配置助手-v$Version"
$ZipFileName = "$ReleaseName.zip"
$ZipFilePath = Join-Path $OutputDir $ZipFileName
$Sha256FilePath = "$ZipFilePath.sha256"

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "            Release ZIP 打包脚本 v$Version                        " -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "项目目录: $ProjectRoot"
Write-Host "输出目录: $OutputDir"
Write-Host "版本号:   $Version"
Write-Host ""

# ============================================================
# 验证必要文件存在
# ============================================================

Write-Host "[1/5] 验证必要文件..." -ForegroundColor Cyan

$RequiredFiles = @(
    "开始安装.cmd",
    "一键诊断.cmd",
    "恢复或卸载配置.cmd",
    "Start-Install.cmd",
    "Run-Diagnostics.cmd",
    "Restore-Config.cmd",
    "Start-Here.ps1",
    "install.ps1",
    "configure-deepseek.ps1",
    "doctor.ps1",
    "uninstall-config.ps1",
    "install_wsl.sh",
    "lib/bootstrap.ps1",
    "lib/common.ps1",
    "lib/env-check.ps1",
    "lib/config-writer.ps1",
    "lib/logger.ps1",
    "lib/deepseek-env.defaults.json",
    "scripts/check.ps1",
    "scripts/check.sh",
    "README.md",
    "QUICK_START.md",
    "LICENSE"
)

$missing = @()
foreach ($file in $RequiredFiles) {
    $fullPath = Join-Path $ProjectRoot $file
    if (-not (Test-Path $fullPath)) {
        $missing += $file
        Write-Host "  [MISSING] $file" -ForegroundColor Red
    }
    else {
        Write-Host "  [OK] $file" -ForegroundColor Green
    }
}

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "错误: 以下必要文件缺失:" -ForegroundColor Red
    foreach ($m in $missing) {
        Write-Host "  - $m" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "请确保所有文件已创建并提交到 Git（或存在于工作目录中）。" -ForegroundColor Yellow
    exit 1
}

Write-Host "  所有必要文件验证通过。" -ForegroundColor Green
Write-Host ""

# ============================================================
# 创建输出目录
# ============================================================

Write-Host "[2/5] 准备输出目录..." -ForegroundColor Cyan

if (Test-Path $OutputDir) {
    Write-Host "  清理旧的 release 目录..."
    Remove-Item -Path $OutputDir -Recurse -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
Write-Host "  输出目录: $OutputDir" -ForegroundColor Green
Write-Host ""

# ============================================================
# 收集要打包的文件（统一走 staging 目录）
# ============================================================

Write-Host "[3/5] 收集文件..." -ForegroundColor Cyan
Write-Host "  使用文件系统方式打包（统一 staging 流程，确保 API Key 扫描必定执行）..." -ForegroundColor Green
Write-Host ""

# 白名单：只有这些文件/目录可以进入 release ZIP
# 任何未列出的文件都会被排除，防止本地临时文件误入商品包
# docs/ 和 examples/ 使用文件级白名单，防止截图/草稿/内部文档误入
$AllowedEntries = @(
    # === 入口文件 ===
    "开始安装.cmd",
    "一键诊断.cmd",
    "恢复或卸载配置.cmd",
    "Start-Install.cmd",
    "Run-Diagnostics.cmd",
    "Restore-Config.cmd",
    # === 主脚本 ===
    "Start-Here.ps1",
    "install.ps1",
    "configure-deepseek.ps1",
    "doctor.ps1",
    "uninstall-config.ps1",
    "install_wsl.sh",
    # === lib 目录（随迭代增减，允许整目录复制） ===
    "lib",
    # === docs 文件级白名单 ===
    "docs/用户使用教程.md",
    "docs/常见问题FAQ.md",
    "docs/闲鱼商品说明.md",
    "docs/测试清单.md",
    "docs/视频教程脚本.md",
    # === examples 文件级白名单 ===
    "examples/settings.deepseek.example.json",
    "examples/report.example.txt",
    # === scripts 文件级白名单 ===
    "scripts/check.ps1",
    "scripts/check.sh",
    # === 根目录文档 ===
    "README.md",
    "QUICK_START.md",
    "LICENSE"
)

# 创建临时 staging 目录
$tempDir = Join-Path $env:TEMP "ccdi_build_$PID"
if (Test-Path $tempDir) {
    Remove-Item -Path $tempDir -Recurse -Force
}
$stagingDir = Join-Path $tempDir $ReleaseName
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

# ============================================================
# 3.4 源目录 API Key 预扫描（allow-list 过滤前）
# 扫描项目源目录中的文本文件，防止误将真实 Key 提交到仓库后
# 即使文件不在 allow-list 中也能捕获
# ============================================================

# 共享定义（源预扫描和 staging 扫描共用）
$safePlaceholders = @(
    "sk-你的DeepSeekKey",
    "sk-xxxx",
    "__API_KEY__",
    "sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    "sk-1234567890abcdef1234567890abcdef",  # scripts/check.ps1 的 Mask-ApiKey 单元测试 Key
    "sk-leaktest"  # 发布前验收清单的泄漏测试 Key
)

$dangerPatterns = @(
    'sk-[A-Za-z0-9]{20,}',
    'ANTHROPIC_AUTH_TOKEN.*sk-',
    'DEEPSEEK_API_KEY.*sk-',
    'CCDI_API_KEY.*sk-'
)

$textExtensions = @("*.ps1", "*.psm1", "*.sh", "*.json", "*.md", "*.txt", "*.cmd", "*.bat",
                    "*.js", "*.ts", "*.py", "*.html", "*.css", "*.yaml", "*.yml",
                    "*.xml", "*.ini", "*.cfg", "*.conf", "*.env", "*.example")

Write-Host ""
Write-Host "[3.4/5] 源目录 API Key 预扫描..." -ForegroundColor Cyan

$sourceScanExcludes = @(".git", "logs", "backup", "reports", "release", "node_modules")

$sourceApiHits = [System.Collections.Generic.List[object]]::new()

function Test-SourceFileForApiKey {
    param([string]$FilePath, [string]$DisplayPath)

    try {
        $content = Get-Content -Path $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $content) { return }

        foreach ($pattern in $dangerPatterns) {
            $matches = [regex]::Matches($content, $pattern)
            foreach ($m in $matches) {
                $candidate = $m.Value.Trim()
                $isSafe = $false
                foreach ($safe in $safePlaceholders) {
                    if ($candidate -match [regex]::Escape($safe)) {
                        $isSafe = $true
                        break
                    }
                }
                if (-not $isSafe) {
                    $keyPart = $candidate -replace '^.*?(sk-[A-Za-z0-9]{20,})', '$1'
                    if ($keyPart.Length -ge 32) {
                        [void]$sourceApiHits.Add([PSCustomObject]@{
                            File    = $DisplayPath
                            Pattern = $pattern
                            Match   = ($candidate.Substring(0, [Math]::Min(60, $candidate.Length)) + "...")
                        })
                    }
                }
            }
        }
    }
    catch { }
}

$sourceTextFiles = @()
foreach ($ext in $textExtensions) {
    $sourceTextFiles += Get-ChildItem -Path $ProjectRoot -Filter $ext -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $full = $_.FullName
            $skip = $false
            foreach ($excl in $sourceScanExcludes) {
                if ($full -match "\\$excl\\" -or $full -match "\\$excl`$" -or $full -match "/$excl/" -or $full -match "/$excl`$") {
                    $skip = $true
                    break
                }
            }
            -not $skip
        }
}
$sourceTextFiles = $sourceTextFiles | Sort-Object FullName -Unique

foreach ($file in $sourceTextFiles) {
    $relPath = $file.FullName.Substring($ProjectRoot.Length + 1)
    Test-SourceFileForApiKey -FilePath $file.FullName -DisplayPath $relPath
}

if ($sourceApiHits.Count -gt 0) {
    Write-Host ""
    Write-Host "错误: 在项目源文件中扫描到疑似真实 API Key，已中止发布。" -ForegroundColor Red
    Write-Host ""
    foreach ($hit in $sourceApiHits) {
        Write-Host "  [$($hit.File)]" -ForegroundColor Red
        Write-Host "    匹配模式: $($hit.Pattern)" -ForegroundColor DarkYellow
        Write-Host "    内容片段: $($hit.Match)" -ForegroundColor DarkYellow
    }
    Write-Host ""
    Write-Host "请确认以上文件中的 sk-... 是否为真实 API Key。" -ForegroundColor Yellow
    Write-Host "如果是真实 Key，请立即删除并到 DeepSeek 平台重新生成。" -ForegroundColor Yellow
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $OutputDir) {
        Remove-Item -Path $OutputDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 1
}

Write-Host "  源目录预扫描通过，未发现真实 API Key。" -ForegroundColor Green

# 按白名单复制文件
foreach ($entry in $AllowedEntries) {
    $sourcePath = Join-Path $ProjectRoot $entry
    $destPath = Join-Path $stagingDir $entry

    if (-not (Test-Path $sourcePath)) {
        Write-Host "  错误: 白名单条目不存在: $entry" -ForegroundColor Red
        Write-Host "  正式 release 不允许缺失必要文件，请检查项目完整性。" -ForegroundColor Yellow
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $OutputDir) { Remove-Item -Path $OutputDir -Recurse -Force -ErrorAction SilentlyContinue }
        exit 1
    }

    if (Test-Path $sourcePath -PathType Container) {
        # 目录：递归复制全部内容
        $destParent = Split-Path -Parent $destPath
        if (-not (Test-Path $destParent)) {
            New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        }
        Copy-Item -Path $sourcePath -Destination $destPath -Recurse -Force
        $fileCount = (Get-ChildItem -Path $destPath -Recurse -File -ErrorAction SilentlyContinue).Count
        Write-Host "  [ADD] $entry/ ($fileCount files)" -ForegroundColor Green
    }
    else {
        # 单个文件
        $destParent = Split-Path -Parent $destPath
        if ($destParent -and -not (Test-Path $destParent)) {
            New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        }
        Copy-Item -Path $sourcePath -Destination $destPath -Force
        Write-Host "  [ADD] $entry" -ForegroundColor Green
    }
}

# 输出打包摘要
$totalFiles = (Get-ChildItem -Path $stagingDir -Recurse -File -ErrorAction SilentlyContinue).Count
Write-Host ""
Write-Host "  Staging 目录共 $totalFiles 个文件" -ForegroundColor Cyan

    # ============================================================
    # 3.45 编码规范化：.ps1 加 BOM，.cmd 验证 ASCII 无 BOM
    # ============================================================

    Write-Host ""
    Write-Host "[3.45/5] 编码规范化..." -ForegroundColor Cyan

    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    # .ps1/.psm1: 确保有 UTF-8 BOM（PowerShell 5.1 需要 BOM 才能正确解析中文）
    $psFiles = Get-ChildItem -Path $stagingDir -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
    $psFiles += Get-ChildItem -Path $stagingDir -Filter "*.psm1" -Recurse -ErrorAction SilentlyContinue

    foreach ($f in $psFiles) {
        $raw = [System.IO.File]::ReadAllBytes($f.FullName)
        $hasBom = ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)
        if (-not $hasBom) {
            [System.IO.File]::WriteAllText($f.FullName, [System.Text.Encoding]::UTF8.GetString($raw), $utf8Bom)
            Write-Host "  [BOM] $($f.Name)" -ForegroundColor Cyan
        }
    }

    # .cmd: 验证无 BOM + 纯 ASCII
    $cmdFiles = Get-ChildItem -Path $stagingDir -Filter "*.cmd" -Recurse -ErrorAction SilentlyContinue
    foreach ($f in $cmdFiles) {
        $raw = [System.IO.File]::ReadAllBytes($f.FullName)
        $hasBom = ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)
        $nonAscii = $raw | Where-Object { $_ -gt 0x7F }
        if ($hasBom) {
            Write-Host "  错误: $($f.Name) 包含 UTF-8 BOM，CMD 会乱码" -ForegroundColor Red
            Write-Host "  请确保 .cmd 文件为纯 ASCII 无 BOM。" -ForegroundColor Yellow
            Remove-Item $ZipFilePath -Force -ErrorAction SilentlyContinue
            Remove-Item $Sha256FilePath -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $OutputDir) { Remove-Item -Path $OutputDir -Recurse -Force -ErrorAction SilentlyContinue }
            exit 1
        }
        if ($nonAscii) {
            Write-Host "  错误: $($f.Name) 包含 $($nonAscii.Count) 个非 ASCII 字节，CMD 会乱码" -ForegroundColor Red
            Write-Host "  请将 .cmd 文件改为纯 ASCII。" -ForegroundColor Yellow
            Remove-Item $ZipFilePath -Force -ErrorAction SilentlyContinue
            Remove-Item $Sha256FilePath -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $OutputDir) { Remove-Item -Path $OutputDir -Recurse -Force -ErrorAction SilentlyContinue }
            exit 1
        }
    }

    # .ps1/.psm1 构建时校验：必须都有 BOM
    $psFilesNoBom = $psFiles | Where-Object {
        $raw = [System.IO.File]::ReadAllBytes($_.FullName)
        -not ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)
    }
    if ($psFilesNoBom) {
        Write-Host "  错误: 以下 .ps1/.psm1 文件缺少 UTF-8 BOM：" -ForegroundColor Red
        foreach ($f in $psFilesNoBom) { Write-Host "    - $($f.Name)" -ForegroundColor Red }
        Write-Host "  PowerShell 5.1 需要 BOM 才能正确解析中文。" -ForegroundColor Yellow
        Remove-Item $ZipFilePath -Force -ErrorAction SilentlyContinue
        Remove-Item $Sha256FilePath -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $OutputDir) { Remove-Item -Path $OutputDir -Recurse -Force -ErrorAction SilentlyContinue }
        exit 1
    }

    Write-Host "  .ps1 BOM 修复: $($psFiles.Count) 个文件"
    Write-Host "  .cmd 编码验证: $($cmdFiles.Count) 个文件，全部通过"
    Write-Host "  编码规范化完成。" -ForegroundColor Green

    # ============================================================
    # 3.47 Bootstrap 导出检查
    # ============================================================

    Write-Host ""
    Write-Host "[3.47/5] Bootstrap 导出检查..." -ForegroundColor Cyan

    Push-Location $stagingDir
    try {
        . .\lib\bootstrap.ps1
        Initialize-CcdiScript -ScriptName "bootstrap-smoke" | Out-Null

        $requiredCommands = @(
            "Write-Log",
            "Write-Info",
            "Write-Success",
            "Write-Warning",
            "Write-Error-Msg",
            "Write-FatalError",
            "Invoke-CommandSafe",
            "Get-DesktopPath",
            "Get-WindowsVersionInfo",
            "Test-ClaudeInstalled",
            "Write-DeepSeekConfig",
            "Get-DeepSeekConfigStatus"
        )

        foreach ($cmd in $requiredCommands) {
            if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
                throw "Bootstrap 导出检查失败：未找到 $cmd"
            }
        }
    }
    finally {
        Pop-Location
        Remove-Item -Path (Join-Path $stagingDir "logs") -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "  Bootstrap 导出检查通过。" -ForegroundColor Green

    # ============================================================
    # 3.5 扫描文件内容，防止真实 API Key 泄露
    # ============================================================

    Write-Host ""
    Write-Host "[3.5/5] 扫描 staging 文件内容中的 API Key..." -ForegroundColor Cyan

    $apiKeyHits = [System.Collections.Generic.List[object]]::new()

    function Test-ContainsRealApiKey {
        param([string]$FilePath, [string]$DisplayPath)

        try {
            $content = Get-Content -Path $FilePath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if (-not $content) { return }

            foreach ($pattern in $dangerPatterns) {
                $matches = [regex]::Matches($content, $pattern)
                foreach ($m in $matches) {
                    $candidate = $m.Value.Trim()

                    # 检查是否为安全占位符
                    $isSafe = $false
                    foreach ($safe in $safePlaceholders) {
                        if ($candidate -match [regex]::Escape($safe)) {
                            $isSafe = $true
                            break
                        }
                    }

                    if (-not $isSafe) {
                        # 提取纯 Key 部分（去掉前缀如 ANTHROPIC_AUTH_TOKEN=）
                        $keyPart = $candidate -replace '^.*?(sk-[A-Za-z0-9]{20,})', '$1'

                        # 如果 Key 看起来像真实 Key（足够长且复杂）
                        if ($keyPart.Length -ge 32) {
                            [void]$apiKeyHits.Add([PSCustomObject]@{
                                File    = $DisplayPath
                                Pattern = $pattern
                                Match   = ($candidate.Substring(0, [Math]::Min(60, $candidate.Length)) + "...")
                            })
                        }
                    }
                }
            }
        }
        catch {
            Write-Host "    [WARN] 无法扫描: $DisplayPath" -ForegroundColor DarkGray
        }
    }

    # 扫描 staging 目录中的所有文本文件
    $scanFiles = @()
    foreach ($ext in $textExtensions) {
        $scanFiles += Get-ChildItem -Path $stagingDir -Filter $ext -Recurse -ErrorAction SilentlyContinue
    }

    # 也扫描无扩展名的文件（如 LICENSE）
    $scanFiles += Get-ChildItem -Path $stagingDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq "" }

    $scanFiles = $scanFiles | Sort-Object FullName -Unique

    foreach ($file in $scanFiles) {
        $relPath = $file.FullName.Substring($stagingDir.Length + 1)
        Test-ContainsRealApiKey -FilePath $file.FullName -DisplayPath $relPath
    }

    if ($apiKeyHits.Count -gt 0) {
        Write-Host ""
        Write-Host "错误: 在待打包文件中扫描到疑似真实 API Key，已中止发布。" -ForegroundColor Red
        Write-Host ""
        foreach ($hit in $apiKeyHits) {
            Write-Host "  [$($hit.File)]" -ForegroundColor Red
            Write-Host "    匹配模式: $($hit.Pattern)" -ForegroundColor DarkYellow
            Write-Host "    内容片段: $($hit.Match)" -ForegroundColor DarkYellow
        }
        Write-Host ""
        Write-Host "请确认以上文件中的 sk-... 是否为真实 API Key。" -ForegroundColor Yellow
        Write-Host "如果是占位符，请替换为安全占位符（如 sk-你的DeepSeekKey 或 __API_KEY__）。" -ForegroundColor Yellow
        Write-Host "如果是真实 Key，请立即删除并到 DeepSeek 平台重新生成。" -ForegroundColor Yellow

        # 清理临时目录和输出文件
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $OutputDir) {
            Remove-Item -Path $OutputDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        exit 1
    }

    Write-Host "  内容扫描通过，未发现真实 API Key。" -ForegroundColor Green

    Write-Host ""
    Write-Host "  正在创建 ZIP..."

    # 使用 .NET 压缩（更可靠，支持中文路径）
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    if (Test-Path $ZipFilePath) {
        Remove-Item $ZipFilePath -Force
    }

    [System.IO.Compression.ZipFile]::CreateFromDirectory($stagingDir, $ZipFilePath)

    # 清理临时目录
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "  ZIP 已创建: $ZipFilePath" -ForegroundColor Green

# ============================================================
# 生成 SHA256
# ============================================================

Write-Host ""
Write-Host "[4/5] 生成 SHA256..." -ForegroundColor Cyan

if (-not $SkipSha256) {
    try {
        $sha256 = (Get-FileHash -Path $ZipFilePath -Algorithm SHA256).Hash.ToLower()
        $sha256Content = "$sha256  $ZipFileName"
        [System.IO.File]::WriteAllText($Sha256FilePath, $sha256Content, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "  SHA256: $sha256" -ForegroundColor Green
        Write-Host "  SHA256 文件: $Sha256FilePath" -ForegroundColor Green
    }
    catch {
        Write-Host "  SHA256 生成失败: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
else {
    Write-Host "  已跳过 SHA256 生成。" -ForegroundColor Yellow
}

# ============================================================
# 验证 ZIP 内容
# ============================================================

Write-Host ""
Write-Host "[5/5] 验证 ZIP 内容..." -ForegroundColor Cyan

$zip = [System.IO.Compression.ZipFile]::OpenRead($ZipFilePath)
$entries = $zip.Entries | ForEach-Object { $_.FullName } | Sort-Object

$forbiddenPatterns = @(
    ".git/",
    "logs/",
    "backup/",
    "reports/",
    "report.txt",
    ".tmp",
    "node_modules/"
)

$issues = @()
foreach ($entry in $entries) {
    foreach ($pattern in $forbiddenPatterns) {
        if ($entry -like "*$pattern*") {
            $issues += $entry
            Write-Host "  [WARN] 不应包含: $entry" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "  ZIP 包含 $($zip.Entries.Count) 个条目" -ForegroundColor Green

$zip.Dispose()

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "错误: ZIP 中发现 $($issues.Count) 个不应包含的条目，已中止发布。" -ForegroundColor Red
    foreach ($i in $issues) {
        Write-Host "  - $i" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "请检查 .gitignore 和排除规则，修复后重新打包。" -ForegroundColor Yellow
    Remove-Item $ZipFilePath -Force -ErrorAction SilentlyContinue
    Remove-Item $Sha256FilePath -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Host "  验证通过，没有不应包含的条目。" -ForegroundColor Green

# ============================================================
# 完成
# ============================================================

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Green
Write-Host "                     打包完成！                               " -ForegroundColor Green
Write-Host "==============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Release ZIP: $ZipFilePath" -ForegroundColor Cyan
Write-Host "  文件大小:    $([math]::Round((Get-Item $ZipFilePath).Length / 1KB, 1)) KB" -ForegroundColor Cyan
if (-not $SkipSha256) {
    Write-Host "  SHA256:      $Sha256FilePath" -ForegroundColor Cyan
}
Write-Host ""
Write-Host "  下一步: 将此 ZIP 上传到 Release 或分发给用户。" -ForegroundColor White
Write-Host ""
