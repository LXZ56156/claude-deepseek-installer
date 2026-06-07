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
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║            Release ZIP 打包脚本 v$Version                        ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
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
# 收集要打包的文件
# ============================================================

Write-Host "[3/5] 收集文件..." -ForegroundColor Cyan

# 使用 git archive 如果可用且是 git 仓库
$isGitRepo = Test-Path (Join-Path $ProjectRoot ".git")
$useGitArchive = $isGitRepo -and (Get-Command git -ErrorAction SilentlyContinue)

# 首先检查哪些新增文件不在 Git 中
if ($useGitArchive) {
    Push-Location $ProjectRoot
    try {
        $untrackedNew = @()
        $newFiles = @("开始安装.cmd", "一键诊断.cmd", "恢复或卸载配置.cmd", "Start-Here.ps1", "scripts/build-release.ps1")
        foreach ($f in $newFiles) {
            $gitStatus = git status --porcelain $f 2>$null
            if ($gitStatus) {
                $untrackedNew += $f
                Write-Host "  [WARN] $f 未在 Git 中跟踪" -ForegroundColor Yellow
            }
        }
        if ($untrackedNew.Count -gt 0) {
            Write-Host "  注意: 以上文件需要通过 git add 跟踪后才能被 git archive 包含。" -ForegroundColor Yellow
            Write-Host "  将使用文件系统方式打包。" -ForegroundColor Yellow
            $useGitArchive = $false
        }
    }
    finally {
        Pop-Location
    }
}

if ($useGitArchive) {
    Write-Host "  使用 git archive 打包..." -ForegroundColor Green
    Push-Location $ProjectRoot
    try {
        # git archive 自动遵守 .gitignore
        git archive --format zip --output $ZipFilePath HEAD
        Write-Host "  git archive 完成。" -ForegroundColor Green
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Host "  使用文件系统方式打包..." -ForegroundColor Green
    Write-Host ""

    # 构建排除模式
    $ExcludePatterns = @(
        # Git
        ".git",
        ".gitignore",
        ".gitattributes",
        ".gitmodules",
        # IDE
        ".vscode",
        ".idea",
        "*.sln",
        "*.csproj",
        # 运行时数据
        "logs",
        "backup",
        "reports",
        # 报告文件
        "report*.txt",
        "report*.md",
        # 临时文件
        "*.tmp",
        "*.log",
        "*.bak",
        # 系统文件
        "Thumbs.db",
        ".DS_Store",
        "desktop.ini",
        # release 目录自身
        "release"
        # CLAUDE.md (项目开发用，非用户文档)
        # 保留，用户可能想看
    )

    # 用于 ZipFile.CreateFromDirectory 的排除逻辑
    # PowerShell 5.1 没有 Compress-Archive 的排除功能，所以我们需要手动过滤

    $tempDir = Join-Path $env:TEMP "ccdi_build_$PID"
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path (Join-Path $tempDir $ReleaseName) -Force | Out-Null

    # 递归复制文件，排除指定模式
    function Copy-Filtered {
        param(
            [string]$SourceDir,
            [string]$DestDir,
            [string[]]$Excludes,
            [string]$RelativePath = ""
        )

        $items = Get-ChildItem -Path $SourceDir -Force -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            $itemRelPath = if ($RelativePath) { "$RelativePath/$($item.Name)" } else { $item.Name }

            # 检查是否需要排除
            $exclude = $false
            foreach ($pattern in $Excludes) {
                # 通配符匹配
                if ($item.Name -like $pattern) {
                    $exclude = $true
                    break
                }
                # 目录精确匹配
                if ($item.PSIsContainer -and $item.Name -eq $pattern) {
                    $exclude = $true
                    break
                }
            }

            if ($exclude) {
                Write-Host "  [SKIP] $itemRelPath" -ForegroundColor DarkGray
                continue
            }

            if ($item.PSIsContainer) {
                $newDestDir = Join-Path $DestDir $item.Name
                New-Item -ItemType Directory -Path $newDestDir -Force | Out-Null
                Copy-Filtered -SourceDir $item.FullName -DestDir $newDestDir -Excludes $Excludes -RelativePath $itemRelPath
            }
            else {
                $destFile = Join-Path $DestDir $item.Name
                Copy-Item -Path $item.FullName -Destination $destFile -Force
                Write-Host "  [ADD] $itemRelPath" -ForegroundColor Green
            }
        }
    }

    $stagingDir = Join-Path $tempDir $ReleaseName
    Copy-Filtered -SourceDir $ProjectRoot -DestDir $stagingDir -Excludes $ExcludePatterns

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
}

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

# 检查是否有文件包含完整 API Key（基本检查）
# 注意：这只检查 ZIP 条目的文件名和路径，不检查内容
# 完整的内容审计应在 git pre-commit hook 中进行

Write-Host ""
Write-Host "  ZIP 包含 $($zip.Entries.Count) 个条目" -ForegroundColor Green

$zip.Dispose()

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "警告: 发现 $($issues.Count) 个不应包含的条目。" -ForegroundColor Yellow
    Write-Host "请检查 .gitignore 和排除规则。" -ForegroundColor Yellow
}
else {
    Write-Host "  验证通过，没有不应包含的条目。" -ForegroundColor Green
}

# ============================================================
# 完成
# ============================================================

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                     打包完成！                               ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Release ZIP: $ZipFilePath" -ForegroundColor Cyan
Write-Host "  文件大小:    $([math]::Round((Get-Item $ZipFilePath).Length / 1KB, 1)) KB" -ForegroundColor Cyan
if (-not $SkipSha256) {
    Write-Host "  SHA256:      $Sha256FilePath" -ForegroundColor Cyan
}
Write-Host ""
Write-Host "  下一步: 将此 ZIP 上传到 Release 或分发给用户。" -ForegroundColor White
Write-Host ""
