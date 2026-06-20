# ============================================================
# common.ps1 - 公共工具函数
# 提供路径管理、备份、密钥脱敏、JSON 处理等通用功能
#
# 依赖: logger.ps1（需要先由调用方 dot-source）
# 注意: 本模块不自行 dot-source 依赖模块，由入口脚本统一管理加载顺序
# ============================================================

# ============================================================
# 路径和目录函数
# ============================================================

function Initialize-CcdiNetworkDefaults {
    <#
    .SYNOPSIS
        初始化网络默认设置（TLS 1.2 兼容性修复）。
        仅针对 Windows PowerShell Desktop 设置，不影响 PowerShell Core。
        失败不阻断脚本执行。
    #>
    try {
        if ($PSVersionTable.PSEdition -eq "Desktop") {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Write-Log "DEBUG" "已设置 .NET SecurityProtocol = Tls12"
        }
    }
    catch {
        Write-Log "WARN" "设置 TLS 1.2 失败: $_"
    }
}

function Get-UserProfilePath {
    <#
    .SYNOPSIS
        获取当前用户目录路径，兼容中文 Windows
    #>
    if ($env:CCDI_TEST_MODE -eq "1" -and -not [string]::IsNullOrWhiteSpace($env:CCDI_TEST_USERPROFILE)) {
        return $env:CCDI_TEST_USERPROFILE
    }

    return [System.Environment]::GetFolderPath('UserProfile')
}

function Get-DesktopPath {
    <#
    .SYNOPSIS
        获取当前用户桌面路径。测试模式下可重定向到临时目录。
    #>
    if ($env:CCDI_TEST_MODE -eq "1" -and -not [string]::IsNullOrWhiteSpace($env:CCDI_TEST_DESKTOP)) {
        return $env:CCDI_TEST_DESKTOP
    }

    return [Environment]::GetFolderPath("Desktop")
}

function Get-ClaudeConfigDir {
    <#
    .SYNOPSIS
        获取 Claude Code 配置目录路径 (Windows)
    #>
    return Join-Path (Get-UserProfilePath) ".claude"
}

function Get-ClaudeConfigFile {
    <#
    .SYNOPSIS
        获取 Claude Code settings.json 完整路径 (Windows)
    #>
    return Join-Path (Get-ClaudeConfigDir) "settings.json"
}

function Get-BackupDir {
    <#
    .SYNOPSIS
        获取备份目录路径
    #>
    if (Get-Variable -Name CcdiProjectRoot -Scope Script -ErrorAction SilentlyContinue) {
        return Join-Path $script:CcdiProjectRoot "backup"
    }

    $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }
    return Join-Path $scriptRoot "..\backup"
}

function Get-ScriptRoot {
    <#
    .SYNOPSIS
        获取脚本所在目录
    #>
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }
    return Split-Path -Parent $MyInvocation.MyCommand.Path
}

# ============================================================
# 备份函数
# ============================================================

function Backup-File {
    <#
    .SYNOPSIS
        备份指定文件到 backup 目录，文件名带时间戳
    .PARAMETER FilePath
        要备份的文件路径
    .RETURNS
        备份文件路径，如果备份失败则返回 $null
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    if (-not (Test-Path $FilePath)) {
        Write-Log "INFO" "备份: 文件不存在，无需备份: $FilePath"
        return $null
    }

    try {
        $backupDir = Get-BackupDir
        $fullBackupDir = [System.IO.Path]::GetFullPath($backupDir)

        # 创建备份目录
        if (-not (Test-Path $fullBackupDir)) {
            New-Item -ItemType Directory -Path $fullBackupDir -Force | Out-Null
            Write-Log "INFO" "创建备份目录: $fullBackupDir"
        }

        # 生成备份文件名
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
        $fileName = [System.IO.Path]::GetFileName($FilePath)
        $backupName = "$fileName.$timestamp.bak"
        $backupPath = Join-Path $fullBackupDir $backupName

        Copy-Item -Path $FilePath -Destination $backupPath -Force
        Write-Log "INFO" "已备份: $FilePath -> $backupPath"
        Write-Info "已备份旧配置文件到: $backupPath"
        return $backupPath
    }
    catch {
        Write-Error-Msg "备份失败: $FilePath"
        Write-Log "ERROR" "备份失败: $_"
        return $null
    }
}

# ============================================================
# ZIP 内运行检测
# ============================================================

function Test-IsZipInternalPath {
    <#
    .SYNOPSIS
        检测当前脚本运行路径是否疑似压缩包临时目录。
        如果用户在 ZIP 预览窗口中直接双击 .cmd，路径会在临时目录。
    .RETURNS
        包含 IsZipTemp, IsTempPath, Reason, Path 的哈希表。
        IsZipTemp = true  → 明确压缩包临时目录，必须 BLOCK
        IsTempPath = true → 普通 TEMP 目录（仅写日志，不再前台 WARN）
    #>
    param(
        [string]$PathToCheck = $null
    )

    $result = @{
        IsZipTemp  = $false
        IsTempPath = $false
        Reason     = ""
        Path       = ""
    }

    if (-not $PathToCheck) {
        $PathToCheck = (Get-Location).Path
    }
    $result.Path = $PathToCheck

    $normalized = ($PathToCheck -replace '/', '\').TrimEnd('\')
    $lower = $normalized.ToLowerInvariant()

    $tempPath = ""
    if ($env:TEMP) {
        $tempPath = (($env:TEMP -replace '/', '\').TrimEnd('\')).ToLowerInvariant()
    }

    $isUnderTemp = $false
    if ($tempPath) {
        $isUnderTemp = ($lower -eq $tempPath -or $lower.StartsWith($tempPath + "\"))
    }

    $rarRegex = '(?i)(^|\\)rar\$[^\\]*(\\|$)'
    $sevenZipRegex = '(?i)(^|\\)7z[^\\]*(\\|$)'
    $explorerZipRegex = '(?i)(^|\\)temp\d*_[^\\]*\.zip(\\|$)'
    $zipSegmentRegex = '(?i)(^|\\)[^\\]*\.zip(\\|$)'
    $temporaryInternetRegex = '(?i)(^|\\)temporary internet files(\\|$)'
    $compressedRegex = '(?i)(^|\\)compressed(\\|$)'

    # 明确压缩包临时目录特征 → IsZipTemp = true（BLOCK）
    if ($lower -match $rarRegex) {
        $result.IsZipTemp = $true
        $result.Reason = "检测到 WinRAR 临时解压目录。请先完整解压 ZIP 到普通文件夹，例如 D:\\ClaudeDeepSeek。"
        return $result
    }

    if ($isUnderTemp -and $lower -match $sevenZipRegex) {
        $result.IsZipTemp = $true
        $result.Reason = "检测到 7-Zip 临时解压目录。请先完整解压 ZIP 到普通文件夹，例如 D:\\ClaudeDeepSeek。"
        return $result
    }

    if ($isUnderTemp -and ($lower -match $explorerZipRegex -or $lower -match $zipSegmentRegex -or $lower.Contains("_zip_"))) {
        $result.IsZipTemp = $true
        $result.Reason = "检测到 Windows 压缩包临时目录。请先完整解压 ZIP 到普通文件夹，例如 D:\\ClaudeDeepSeek。"
        return $result
    }

    # 浏览器临时目录（无论是否在 TEMP 下都阻断）
    if ($lower -match $temporaryInternetRegex) {
        $result.IsZipTemp = $true
        $result.Reason = "检测到浏览器临时目录。请先完整解压 ZIP 到普通文件夹，例如 D:\\ClaudeDeepSeek。"
        return $result
    }

    # compressed 目录仅在 TEMP 下才阻断（避免 D:\compressed\... 误判）
    if ($isUnderTemp -and $lower -match $compressedRegex) {
        $result.IsZipTemp = $true
        $result.Reason = "检测到压缩包临时目录。请先完整解压 ZIP 到普通文件夹，例如 D:\\ClaudeDeepSeek。"
        return $result
    }

    # ============================================================
    # 第 2 遍：普通 TEMP 目录 → IsTempPath = true（仅写日志，不前台 WARN）
    # ============================================================
    if ($isUnderTemp) {
        $result.IsTempPath = $true
        $result.Reason = "当前路径在系统临时目录中。"
        return $result
    }

    return $result
}

# ============================================================
# 路径风险检测
# ============================================================

function Test-UserPathRisk {
    <#
    .SYNOPSIS
        仅阻断 ZIP 预览/临时解压路径；常见用户目录（桌面、下载、OneDrive、微信/QQ接收目录）默认允许，不在前台警告。
    .PARAMETER PathToCheck
        要检测的路径。默认使用当前目录。
    .RETURNS
        包含 RiskLevel, RiskItems, Suggestions, IsBlocked 的哈希表
        RiskLevel: BLOCK|WARN|INFO
    #>
    param(
        [string]$PathToCheck = $null
    )

    $result = @{
        RiskLevel   = "INFO"
        RiskItems   = [System.Collections.ArrayList]::new()
        IsBlocked   = $false
        Suggestions = [System.Collections.ArrayList]::new()
        Path        = ""
    }

    if (-not $PathToCheck) {
        $PathToCheck = (Get-Location).Path
    }
    $result.Path = $PathToCheck

    # ZIP 临时目录（BLOCK 级别，必须阻断）
    $zipCheck = Test-IsZipInternalPath -PathToCheck $PathToCheck
    if ($zipCheck.IsZipTemp) {
        $result.RiskLevel = "BLOCK"
        $result.IsBlocked = $true
        [void]$result.RiskItems.Add("ZIP临时目录: $($zipCheck.Reason)")
        [void]$result.Suggestions.Add("请先右键 ZIP 文件 -> 全部解压缩，然后在解压后的文件夹里双击 00-点我开始安装.cmd。不要在压缩包预览窗口中直接运行。")
        return $result
    }

    # 普通 TEMP 目录：仅写日志，不前台 WARN
    if ($zipCheck.IsTempPath) {
        Write-Log "DEBUG" "Project path is under TEMP but not ZIP temp; allowed without user warning: $PathToCheck"
    }

    # WSL 文件系统路径（从 Windows 访问 WSL 文件系统运行 Windows 脚本不适合小白）
    if ($PathToCheck.ToLowerInvariant().Contains("\wsl.localhost") -or
        $PathToCheck.ToLowerInvariant().Contains("\wsl$")) {
        $result.RiskLevel = "WARN"
        [void]$result.RiskItems.Add("当前在 WSL 文件系统路径中运行 Windows 脚本。请把安装包解压到 Windows 桌面、下载目录或 D 盘文件夹后再运行。")
        [void]$result.Suggestions.Add("建议复制到 Windows 本地文件夹后运行，例如桌面或 D:\ClaudeDeepSeek。")
    }

    return $result
}

# ============================================================
# API Key 脱敏函数
# ============================================================

function Mask-ApiKey {
    <#
    .SYNOPSIS
        对 API Key 进行脱敏处理，只显示前4位和后4位
    .PARAMETER Key
        原始 API Key
    .RETURNS
        脱敏后的 Key，如 sk-xx****abcd
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        return "(空)"
    }

    if ($Key.Length -le 8) {
        return $Key.Substring(0, [Math]::Min(2, $Key.Length)) + "****"
    }

    $prefix = $Key.Substring(0, 4)
    $suffix = $Key.Substring($Key.Length - 4, 4)
    return "$prefix****$suffix"
}

function Is-ApiKeyFormatValid {
    <#
    .SYNOPSIS
        检查 API Key 格式是否看起来正确（不验证有效性）
    .PARAMETER Key
        API Key 字符串
    #>
    param([string]$Key)

    if ([string]::IsNullOrWhiteSpace($Key)) {
        return $false
    }

    # 先 trim 以防粘贴带入空格
    $trimmed = $Key.Trim()

    # DeepSeek API Key 通常以 sk- 开头
    if ($trimmed -match '^sk-[a-zA-Z0-9]{32,}$') {
        return $true
    }

    # 通用检查：至少 20 个字符
    # 注意：此函数不输出 UI 提示，避免在诊断等后台场景产生噪音
    if ($trimmed.Length -ge 20) {
        return $true
    }

    return $false
}

function Write-SupportSafeGuidance {
    <#
    .SYNOPSIS
        v1.3.3 UX: 统一售后安全提示。
        所有完成页、报告、README、诊断页共用此模板。
        优先发送 support-feedback.txt；没有时发送 report.txt。
        不发送 backup/logs/full-report/settings.json/API Key。
    .PARAMETER ForReport
        返回纯文本（用于嵌入报告），而非控制台输出。
    #>
    param(
        [switch]$ForReport
    )

    $lines = @(
        "如需售后，请运行「一键诊断.cmd」。",
        "优先发送 support-feedback.txt（汇总反馈文件）。",
        "如没有 support-feedback.txt，再发送 report.txt。",
        "不要发送 backup/、logs/、reports/full-report-*、settings.json。",
        "不要发送完整 API Key。",
        "如果截图，请先确认截图里没有完整 API Key。"
    )

    if ($ForReport) {
        return ($lines -join "`r`n")
    }

    foreach ($line in $lines) {
        Write-Info $line
    }
}

function New-SupportFeedbackReport {
    <#
    .SYNOPSIS
        v1.3.3: 生成统一的售后反馈文件 support-feedback.txt。
        汇总 report.txt、最近日志尾部、终端输出尾部，全部脱敏。
        以后售后默认只让用户发送此文件。
    .PARAMETER OutputPath
        输出路径，默认项目根目录 support-feedback.txt
    .PARAMETER ReportText
        report.txt 的脱敏内容（已通过 Convert-ToSafeReportText 处理）
    .PARAMETER ScriptDir
        项目根目录（用于查找 logs/、reports/ 等）
    .PARAMETER IncludeLogTail
        是否包含最近日志尾部，默认 $true
    .PARAMETER IncludeTerminalTail
        是否包含最近终端输出尾部，默认 $true
    .PARAMETER MaxLogLines
        日志尾部最大行数，默认 200
    .PARAMETER MaxTerminalLines
        终端输出尾部最大行数，默认 200
    .PARAMETER OverallStatus
        当前状态：可用 / 基本可用 / 需要修复 / 未完成
    .PARAMETER ClaudeStatus
        Claude Code 状态描述
    .PARAMETER DeepSeekStatus
        DeepSeek 配置状态描述
    .PARAMETER ApiTestStatus
        API 测试状态描述
    .PARAMETER FreshShellStatus
        Fresh PowerShell 状态描述
    .PARAMETER NextSteps
        下一步建议（字符串数组，最多 3 条）
    .RETURNS
        包含 Success, Path, Error 的哈希表
    #>
    param(
        [string]$OutputPath = "",
        [string]$ReportText = "",
        [string]$ScriptDir = "",
        [switch]$IncludeLogTail = $true,
        [switch]$IncludeTerminalTail = $true,
        [int]$MaxLogLines = 120,
        [int]$MaxTerminalLines = 120,
        [string]$OverallStatus = "未完成",
        [string]$ClaudeStatus = "",
        [string]$DeepSeekStatus = "",
        [string]$ApiTestStatus = "",
        [string]$FreshShellStatus = "",
        [string]$InstallMethod = "",
        [string]$NodeJsStatus = "",
        [string[]]$NextSteps = @()
    )

    $result = @{
        Success = $false
        Path    = ""
        Error   = ""
    }

    try {
        # 确定输出路径
        if (-not $OutputPath) {
            if ($ScriptDir) {
                $OutputPath = Join-Path $ScriptDir "support-feedback.txt"
            }
            else {
                $OutputPath = Join-Path (Get-Location) "support-feedback.txt"
            }
        }
        $result.Path = $OutputPath

        $scriptVersion = "1.3.3"
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $sb = New-Object System.Text.StringBuilder

        # ============================================================
        # 文件头
        # ============================================================
        [void]$sb.AppendLine("Claude Code + DeepSeek 配置助手 - 售后反馈文件")
        [void]$sb.AppendLine("生成时间：$timestamp")
        [void]$sb.AppendLine("工具版本：$scriptVersion")
        [void]$sb.AppendLine("说明：本文件已脱敏，可发送给售后。不要发送 settings.json、backup、logs、full-report 或完整 API Key。")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("=" * 73)

        # ============================================================
        # 一、最简结论
        # ============================================================
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("一、最简结论")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("  - 当前状态：$OverallStatus")
        if ($ClaudeStatus) { [void]$sb.AppendLine("  - Claude Code：$ClaudeStatus") }
        if ($InstallMethod) { [void]$sb.AppendLine("  - 安装方式：$InstallMethod") }
        if ($NodeJsStatus) { [void]$sb.AppendLine("  - Node.js：$NodeJsStatus") }
        if ($DeepSeekStatus) { [void]$sb.AppendLine("  - DeepSeek 配置：$DeepSeekStatus") }
        if ($ApiTestStatus) { [void]$sb.AppendLine("  - API 测试：$ApiTestStatus") }
        if ($FreshShellStatus) { [void]$sb.AppendLine("  - Fresh PowerShell：$FreshShellStatus") }

        if ($NextSteps -and (@($NextSteps)).Count -gt 0) {
            [void]$sb.AppendLine("  - 下一步建议：")
            $stepNum = 1
            foreach ($step in $NextSteps) {
                if ($stepNum -gt 3) { break }
                [void]$sb.AppendLine("    $stepNum. $step")
                $stepNum++
            }
        }

        # ============================================================
        # 二、诊断报告 report.txt
        # ============================================================
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("=" * 73)
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("二、诊断报告 report.txt")
        [void]$sb.AppendLine("")
        if ($ReportText) {
            # ReportText 已经过 Convert-ToSafeReportText 处理，再次确保脱敏
            $safeReport = Sanitize-SecretLikeText -Text $ReportText
            [void]$sb.AppendLine($safeReport)
        }
        else {
            [void]$sb.AppendLine("  未提供诊断报告内容。")
        }

        # ============================================================
        # 三、最近安装报告摘要
        # ============================================================
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("=" * 73)
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("三、最近安装报告摘要")
        [void]$sb.AppendLine("")

        $foundInstallReport = $false
        if ($ScriptDir) {
            # 查找 reports/ 下的 install-report 或安装完成报告
            $reportsDir = Join-Path $ScriptDir "reports"
            $installReports = @()
            if (Test-Path $reportsDir) {
                $installReports = @(Get-ChildItem -Path $reportsDir -Filter "install-report-*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            }
            # 也检查项目根目录
            $rootReports = @(Get-ChildItem -Path $ScriptDir -Filter "install-report-*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            $installReports = @(@($installReports) + @($rootReports) | Sort-Object LastWriteTime -Descending)

            if ($installReports.Count -gt 0) {
                $foundInstallReport = $true
                $latestReport = $installReports[0]
                try {
                    $reportContent = Get-Content $latestReport.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if ($reportContent) {
                        $safeContent = Sanitize-SecretLikeText -Text $reportContent
                        $safeContent = Sanitize-PathForReport -Text $safeContent
                        # v1.3.3: 如果安装报告与上方 report.txt 完全一致，省略重复正文
                        if ($ReportText -and ($safeContent.Trim() -eq $ReportText.Trim())) {
                            [void]$sb.AppendLine("  最近安装报告：$($latestReport.Name)")
                            [void]$sb.AppendLine("")
                            [void]$sb.AppendLine("  （与上方 report.txt 内容一致，已省略重复正文。）")
                        }
                        else {
                            # 只取关键摘要段（前 100 行或 5000 字符）
                            $lines = $safeContent -split "`r?`n"
                            $summaryLines = $lines | Select-Object -First 100
                            $summaryText = ($summaryLines -join "`r`n")
                            if ($summaryText.Length -gt 5000) {
                                $summaryText = $summaryText.Substring(0, 5000) + "`r`n...[摘要截断]"
                            }
                            [void]$sb.AppendLine("  最近安装报告：$($latestReport.Name)")
                            [void]$sb.AppendLine("")
                            [void]$sb.AppendLine($summaryText)
                        }
                    }
                }
                catch {
                    Write-Log "WARN" "New-SupportFeedbackReport: 读取安装报告失败 $($latestReport.FullName): $_"
                }
            }
        }
        if (-not $foundInstallReport) {
            [void]$sb.AppendLine("  未找到安装报告。")
        }

        # ============================================================
        # 四、最近运行日志尾部
        # ============================================================
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("=" * 73)
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("四、最近运行日志尾部")
        [void]$sb.AppendLine("")

        if ($IncludeLogTail -and $ScriptDir) {
            $logsDir = Join-Path $ScriptDir "logs"
            if (Test-Path $logsDir) {
                $logFiles = @(Get-ChildItem -Path $logsDir -Filter "*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
                $shownLogs = 0
                $maxLogFiles = 3
                foreach ($logFile in $logFiles) {
                    if ($shownLogs -ge $maxLogFiles) { break }
                    try {
                        $logContent = Get-Content $logFile.FullName -Tail $MaxLogLines -Encoding UTF8 -ErrorAction SilentlyContinue
                        if ($logContent) {
                            $logText = ($logContent -join "`r`n")
                            $safeLog = Sanitize-SecretLikeText -Text $logText
                            $safeLog = Sanitize-PathForReport -Text $safeLog
                            $safeLog = Remove-ProgressNoiseLines -Text $safeLog
                            $safeLog = Remove-PowerShellTerminatingNoiseLines -Text $safeLog
                            [void]$sb.AppendLine("  --- $($logFile.Name)（尾部 $MaxLogLines 行）---")
                            [void]$sb.AppendLine($safeLog)
                            [void]$sb.AppendLine("")
                            $shownLogs++
                        }
                    }
                    catch {
                        Write-Log "WARN" "New-SupportFeedbackReport: 读取日志失败 $($logFile.FullName): $_"
                    }
                }
                if ($shownLogs -eq 0) {
                    [void]$sb.AppendLine("  日志目录存在但无可读日志文件。")
                }
            }
            else {
                [void]$sb.AppendLine("  日志目录不存在。")
            }
        }
        else {
            [void]$sb.AppendLine("  日志尾部已跳过或项目目录未知。")
        }

        # ============================================================
        # 五、最近终端输出尾部
        # ============================================================
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("=" * 73)
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("五、最近终端输出尾部")
        [void]$sb.AppendLine("")

        if ($IncludeTerminalTail -and $ScriptDir) {
            $terminalDir = Join-Path $ScriptDir "logs"
            if (Test-Path $terminalDir) {
                $terminalFiles = @(Get-ChildItem -Path $terminalDir -Filter "terminal-*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
                if ($terminalFiles.Count -gt 0) {
                    $latestTerminal = $terminalFiles[0]
                    try {
                        $termContent = Get-Content $latestTerminal.FullName -Tail $MaxTerminalLines -Encoding UTF8 -ErrorAction SilentlyContinue
                        if ($termContent) {
                            $termText = ($termContent -join "`r`n")
                            $safeTerm = Sanitize-SecretLikeText -Text $termText
                            $safeTerm = Sanitize-PathForReport -Text $safeTerm
                            $safeTerm = Remove-ProgressNoiseLines -Text $safeTerm
                            $safeTerm = Remove-PowerShellTerminatingNoiseLines -Text $safeTerm
                            [void]$sb.AppendLine("  --- $($latestTerminal.Name)（尾部 $MaxTerminalLines 行）---")
                            [void]$sb.AppendLine($safeTerm)
                        }
                    }
                    catch {
                        Write-Log "WARN" "New-SupportFeedbackReport: 读取终端输出失败: $_"
                    }
                }
                else {
                    [void]$sb.AppendLine("  未启用或未找到终端输出记录。")
                }
            }
            else {
                [void]$sb.AppendLine("  未启用或未找到终端输出记录。")
            }
        }
        else {
            [void]$sb.AppendLine("  终端输出尾部已跳过。")
        }

        # ============================================================
        # 六、隐私检查说明
        # ============================================================
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("=" * 73)
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("六、隐私检查说明")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("  - 完整 API Key：已脱敏")
        [void]$sb.AppendLine("  - 用户名/真实路径：已脱敏或最小化")
        [void]$sb.AppendLine("  - settings.json：未包含")
        [void]$sb.AppendLine("  - backup/：未包含")
        [void]$sb.AppendLine("  - full-report：未包含")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("=" * 73)
        [void]$sb.AppendLine("  反馈文件结束")
        [void]$sb.AppendLine("=" * 73)

        # 写入文件
        [System.IO.File]::WriteAllText($OutputPath, $sb.ToString(), $utf8NoBom)
        $result.Success = $true
        Write-Log "INFO" "New-SupportFeedbackReport: 已生成 $OutputPath"
    }
    catch {
        $result.Error = "生成 support-feedback.txt 异常: $($_.Exception.Message)"
        Write-Log "ERROR" $result.Error
    }

    return $result
}

function Read-JsonFileSafe {
    <#
    .SYNOPSIS
        安全读取 JSON 文件，损坏时返回 $null
    .PARAMETER FilePath
        JSON 文件路径
    .RETURNS
        PSCustomObject 或 $null
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    if (-not (Test-Path $FilePath)) {
        Write-Log "DEBUG" "JSON 文件不存在: $FilePath"
        return $null
    }

    try {
        $content = Get-Content -Path $FilePath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($content)) {
            Write-Log "WARN" "JSON 文件为空: $FilePath"
            return $null
        }
        $json = $content | ConvertFrom-Json
        return $json
    }
    catch {
        Write-Log "ERROR" "JSON 解析失败: $FilePath, 错误: $_"
        return $null
    }
}

function Write-JsonFileSafe {
    <#
    .SYNOPSIS
        安全写入 JSON 文件，使用 UTF-8 编码
    .PARAMETER FilePath
        目标文件路径
    .PARAMETER Data
        要写入的数据对象
    .PARAMETER Depth
        JSON 深度，默认 10
    .RETURNS
        是否写入成功
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        $Data,
        [int]$Depth = 10
    )

    try {
        # 确保目录存在
        $dir = Split-Path -Parent $FilePath
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        # 格式化以便人类阅读（缩进 2 空格）
        $formattedJson = ($Data | ConvertTo-Json -Depth $Depth)

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($FilePath, $formattedJson, $utf8NoBom)
        Write-Log "INFO" "JSON 文件已写入: $FilePath"
        return $true
    }
    catch {
        Write-Log "ERROR" "JSON 写入失败: $FilePath, 错误: $_"
        return $false
    }
}

function Test-JsonValid {
    <#
    .SYNOPSIS
        检查文件内容是否为合法 JSON
    .PARAMETER FilePath
        文件路径
    #>
    param([string]$FilePath)

    $json = Read-JsonFileSafe -FilePath $FilePath
    return ($null -ne $json)
}

function Merge-SettingsJson {
    <#
    .SYNOPSIS
        合并新的 env 配置到现有 settings.json
        保留原有字段，只更新 env 部分
    .PARAMETER ExistingPath
        现有 settings.json 路径
    .PARAMETER NewEnv
        要合并的新 env 哈希表
    .RETURNS
        合并后的完整配置对象
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExistingPath,
        [Parameter(Mandatory = $true)]
        [hashtable]$NewEnv
    )

    $existing = Read-JsonFileSafe -FilePath $ExistingPath

    if ($null -eq $existing) {
        # 文件不存在或损坏，返回全新配置（始终返回 PSCustomObject）
        $newConfig = [PSCustomObject]@{}
        Add-Member -InputObject $newConfig -MemberType NoteProperty -Name "env" -Value ([PSCustomObject]$NewEnv)
        return $newConfig
    }

    # 如果已有 env 字段，合并；否则新建
    $mergedEnv = @{}
    $existingProps = @($existing.PSObject.Properties | ForEach-Object { $_.Name })
    if (($existingProps -contains "env") -and $null -ne $existing.env) {
        # 防御：仅当 env 是 PSCustomObject（JSON 对象）时才枚举属性。
        # 如果旧配置中 env 是字符串/数组/布尔值/数字等非对象类型，
        # 枚举其 PSObject.Properties 会产生 Length、Count 等错误字段。
        if ($existing.env -is [System.Management.Automation.PSCustomObject]) {
            foreach ($prop in $existing.env.PSObject.Properties) {
                $mergedEnv[$prop.Name] = $prop.Value
            }
        }
        else {
            Write-Log "WARN" "旧配置中 env 字段类型异常 ($($existing.env.GetType().Name))，将安全重建 env，原字段已备份"
        }
    }

    # 用新值覆盖
    foreach ($key in $NewEnv.Keys) {
        $mergedEnv[$key] = $NewEnv[$key]
    }

    # 构建合并后的对象
    $merged = [PSCustomObject]@{}
    foreach ($prop in $existing.PSObject.Properties) {
        if ($prop.Name -ne "env") {
            Add-Member -InputObject $merged -MemberType NoteProperty -Name $prop.Name -Value $prop.Value
        }
    }
    Add-Member -InputObject $merged -MemberType NoteProperty -Name "env" -Value ([PSCustomObject]$mergedEnv)

    return $merged
}

# ============================================================
# 确认和交互函数
# ============================================================

function Confirm-UserChoice {
    <#
    .SYNOPSIS
        弹出确认提示，要求用户输入 Y/N。
        支持中英文多关键词、空输入默认值、无效输入重新提示。
    .PARAMETER Message
        提示消息
    .PARAMETER Default
        默认值: Yes（空输入返回 $true）、No（空输入返回 $false）、None（空输入重新提示）
    .PARAMETER AllowQuit
        允许 Q / quit / 退出 输入返回 $null
    .RETURNS
        $true（Yes）、$false（No）、$null（Quit）
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("Yes", "No", "None")]
        [string]$Default = "None",

        [switch]$AllowQuit
    )

    $yesKeywords = @("Y", "y", "yes", "YES", "是", "确认", "继续", "好", "ok", "OK")
    $noKeywords = @("N", "n", "no", "NO", "否", "取消", "不", "不继续")
    $quitKeywords = @("Q", "q", "quit", "退出")

    $hint = switch ($Default) {
        "Yes"  { "(Y/n，直接回车=是)" }
        "No"   { "(y/N，直接回车=否)" }
        "None" { "(Y/N)" }
    }

    if ($AllowQuit) {
        $hint = $hint -replace '\)$', '，Q=退出)'
    }

    while ($true) {
        $response = Read-Host "$Message $hint"

        # 处理退出关键词（仅 AllowQuit 开关启用时）
        if ($AllowQuit) {
            $trimmed = if ($null -eq $response) { "" } else { $response.Trim() }
            if ($trimmed -in $quitKeywords) {
                return $null
            }
        }

        # 空输入：按默认值处理
        if ([string]::IsNullOrWhiteSpace($response)) {
            if ($Default -eq "Yes") {
                return $true
            }
            elseif ($Default -eq "No") {
                return $false
            }
            # Default = None：重新提示
            Write-Warning "未识别输入，请输入 Y 或 N。"
            continue
        }

        $trimmed = $response.Trim()

        if ($trimmed -in $yesKeywords) {
            return $true
        }

        if ($trimmed -in $noKeywords) {
            return $false
        }

        if ($AllowQuit -and $trimmed -in $quitKeywords) {
            return $null
        }

        Write-Warning "未识别输入，请输入 Y 或 N。"
        # 重新提示
    }
}

function Read-SecretInput {
    <#
    .SYNOPSIS
        安全读取用户输入（不回显）
    .PARAMETER Prompt
        提示消息
    .RETURNS
        用户输入的字符串
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )

    $secureString = Read-Host -Prompt $Prompt -AsSecureString
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
    try {
        # 去除前后空格（用户粘贴时可能带入）
        $raw = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        return $raw.Trim()
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Read-ApiKeyWithMaskedConfirmation {
    <#
    .SYNOPSIS
        隐藏读取 API Key，并显示脱敏值供用户确认。
    .PARAMETER Prompt
        输入提示。
    .RETURNS
        用户确认后的 API Key；输入 Q 或空值取消时返回 $null。
    #>
    param(
        [string]$Prompt = "请粘贴您的 DeepSeek API Key"
    )

    while ($true) {
        $apiKey = Read-SecretInput -Prompt $Prompt

        if ([string]::IsNullOrWhiteSpace($apiKey)) {
            return $null
        }

        Write-Host ""
        Write-Info "已收到 API Key: $(Mask-ApiKey -Key $apiKey)"
        $choice = Read-Host "按回车继续，输入 R 重新粘贴，输入 Q 取消"

        if ([string]::IsNullOrWhiteSpace($choice)) {
            return $apiKey
        }

        switch ($choice.Trim().ToUpperInvariant()) {
            "R" {
                Write-Info "请重新粘贴 API Key。"
                continue
            }
            "Q" {
                Write-Info "已取消输入 API Key。"
                return $null
            }
            default {
                Write-Info "未识别输入，继续使用当前 API Key。"
                return $apiKey
            }
        }
    }
}

function Get-ApiKeyFromEnvironment {
    <#
    .SYNOPSIS
        从安全环境变量读取 API Key。
    .RETURNS
        包含 Found, Key, Source, Error 的哈希表。Key 不应写入日志。
    #>
    $result = @{
        Found  = $false
        Key    = $null
        Source = $null
        Error  = ""
    }

    foreach ($name in @("CCDI_API_KEY", "DEEPSEEK_API_KEY")) {
        $value = [System.Environment]::GetEnvironmentVariable($name, "Process")
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $result.Found = $true
            $result.Key = $value.Trim()
            $result.Source = $name
            return $result
        }
    }

    $result.Error = "未检测到环境变量 CCDI_API_KEY 或 DEEPSEEK_API_KEY"
    return $result
}

# ============================================================
# PATH 持久化函数 (v1.3.3)
# ============================================================

function Get-NativeClaudeBinPath {
    <#
    .SYNOPSIS
        返回 Claude 官方 Native Install 的默认安装目录。
    .RETURNS
        %USERPROFILE%\.local\bin 的完整路径
    #>
    return Join-Path (Get-UserProfilePath) ".local\bin"
}

function Get-NativeClaudeExePath {
    <#
    .SYNOPSIS
        返回 Claude 官方 Native Install 的 claude.exe 完整路径。
    .RETURNS
        %USERPROFILE%\.local\bin\claude.exe 的完整路径
    #>
    return Join-Path (Get-NativeClaudeBinPath) "claude.exe"
}

function Test-UserPathContains {
    <#
    .SYNOPSIS
        检测 User PATH 环境变量是否包含指定路径。
        大小写不敏感，Trim 空白和末尾反斜杠后比较。
        必须检查注册表（User 级别），而非当前进程 $env:Path。
    .PARAMETER TargetPath
        要检测的路径
    .RETURNS
        包含 Contains, NormalizedTarget, UserPathEntries 的哈希表
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $result = @{
        Contains         = $false
        NormalizedTarget = ""
        UserPathEntries  = @()
    }

    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        return $result
    }

    try {
        $normalizedTarget = ([string]$TargetPath).Trim().TrimEnd('\').ToLowerInvariant()
        $result.NormalizedTarget = $normalizedTarget

        $userPathRaw = [Environment]::GetEnvironmentVariable("Path", "User")
        if ([string]::IsNullOrWhiteSpace($userPathRaw)) {
            Write-Log "DEBUG" "Test-UserPathContains: User PATH 为空"
            return $result
        }

        $entries = $userPathRaw -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $result.UserPathEntries = @($entries)

        foreach ($entry in $entries) {
            if ($entry.ToLowerInvariant() -eq $normalizedTarget) {
                $result.Contains = $true
                Write-Log "DEBUG" "Test-UserPathContains: 路径已在 User PATH 中: $entry"
                break
            }
        }
    }
    catch {
        Write-Log "WARN" "Test-UserPathContains 异常: $_"
    }

    return $result
}

function Ensure-UserPathEntry {
    <#
    .SYNOPSIS
        将指定路径持久化写入 User PATH，不需要管理员权限。
        写入前去重，写入后刷新当前进程 PATH 并验证。
    .PARAMETER PathToAdd
        要加入 User PATH 的路径
    .PARAMETER TestSafe
        测试安全模式：跳过真实写入
    .RETURNS
        包含 Success, Changed, Path, Error 的哈希表
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathToAdd,
        [switch]$TestSafe
    )

    $result = @{
        Success = $false
        Changed = $false
        Path    = $PathToAdd
        Error   = ""
    }

    # 验证路径非空
    if ([string]::IsNullOrWhiteSpace($PathToAdd)) {
        $result.Error = "目标路径为空"
        Write-Log "ERROR" "Ensure-UserPathEntry: $($result.Error)"
        return $result
    }

    # TestSafe 模式：跳过真实写入和目录验证
    if ($TestSafe -or $env:CCDI_TEST_MODE -eq "1") {
        Write-Log "INFO" "TestSafe: 跳过 User PATH 写入: $PathToAdd"

        # 仍检测是否已存在
        $check = Test-UserPathContains -TargetPath $PathToAdd
        $result.Success = $true
        $result.Changed = (-not $check.Contains)
        if ($result.Changed) {
            Write-Log "INFO" "TestSafe: 路径未在 User PATH 中，实际运行时会写入。"
        }
        return $result
    }

    # 真实模式：验证目标目录存在
    if (-not (Test-Path $PathToAdd -PathType Container)) {
        $result.Error = "目标目录不存在: $PathToAdd"
        Write-Log "WARN" "Ensure-UserPathEntry: $($result.Error)"
        return $result
    }

    try {
        # 1. 检测是否已存在
        $check = Test-UserPathContains -TargetPath $PathToAdd
        if ($check.Contains) {
            $result.Success = $true
            $result.Changed = $false
            Write-Log "INFO" "Ensure-UserPathEntry: 路径已在 User PATH 中，无需写入: $PathToAdd"
            return $result
        }

        # 2. 读取当前 User PATH
        $userPathRaw = [Environment]::GetEnvironmentVariable("Path", "User")
        $newUserPath = if ([string]::IsNullOrWhiteSpace($userPathRaw)) {
            $PathToAdd
        }
        else {
            # 去重：确保不重复追加
            $entries = $userPathRaw -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $normalizedAdd = $PathToAdd.Trim().TrimEnd('\')
            $alreadyPresent = $false
            foreach ($entry in $entries) {
                if ($entry.ToLowerInvariant() -eq $normalizedAdd.ToLowerInvariant()) {
                    $alreadyPresent = $true
                    break
                }
            }
            if ($alreadyPresent) {
                $result.Success = $true
                $result.Changed = $false
                Write-Log "INFO" "Ensure-UserPathEntry: 去重检测路径已存在（二次确认），无需写入"
                return $result
            }
            ($entries -join ';') + ';' + $PathToAdd
        }

        # 3. 写入 User PATH
        [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
        Write-Log "INFO" "Ensure-UserPathEntry: 已写入 User PATH: $PathToAdd"

        # 4. 重新读取验证
        $verifyCheck = Test-UserPathContains -TargetPath $PathToAdd
        if (-not $verifyCheck.Contains) {
            $result.Error = "写入后验证失败：User PATH 中仍未找到路径"
            Write-Log "ERROR" "Ensure-UserPathEntry: $($result.Error)"
            return $result
        }

        # 5. 同步刷新当前进程 PATH（让当前窗口立即可用）
        try {
            $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
            $currentProcessPath = $env:Path
            $updatedProcessPath = $newUserPath
            if ($machinePath) {
                $updatedProcessPath = "$updatedProcessPath;$machinePath"
            }
            if ($currentProcessPath) {
                $updatedProcessPath = "$updatedProcessPath;$currentProcessPath"
            }
            $env:Path = $updatedProcessPath
            Write-Log "DEBUG" "Ensure-UserPathEntry: 当前进程 PATH 已同步刷新"
        }
        catch {
            Write-Log "WARN" "Ensure-UserPathEntry: 当前进程 PATH 刷新失败（不影响持久化）: $_"
        }

        $result.Success = $true
        $result.Changed = $true
        Write-Log "INFO" "Ensure-UserPathEntry: 成功写入并验证 User PATH"
    }
    catch {
        $result.Error = "写入 User PATH 异常: $($_.Exception.Message)"
        Write-Log "ERROR" "Ensure-UserPathEntry: $($result.Error)"
    }

    return $result
}

# ============================================================
# Fresh Shell 验证 (v1.3.3)
# ============================================================

function Test-ClaudeCommandInFreshShell {
    <#
    .SYNOPSIS
        启动一个新的 PowerShell -NoProfile 子进程，模拟用户新开窗口后的环境。
        重建 Machine + User PATH 后执行 claude --version。
        不使用当前脚本已污染的 $env:Path。

        v1.3.3 P0-2: 不再通过 Invoke-CommandSafe / cmd.exe 包装。
        改为创建临时 .ps1 检测脚本，用 powershell.exe -File 直接执行，
        独立捕获 stdout/stderr/exit code，避免 cmd 引号/重定向/exit code 丢失。
    .PARAMETER TestSafe
        测试安全模式：跳过真实执行。
    .RETURNS
        包含 Success, Output, Error, ExitCode, Version,
        Reason, CommandPath, UserPathContainsNative, NativeExeExists 的哈希表
    #>
    param(
        [switch]$TestSafe
    )

    $result = @{
        Success               = $false
        Output                = ""
        Error                 = ""
        ExitCode              = -1
        Version               = $null
        Reason                = ""
        CommandPath           = ""
        UserPathContainsNative = $false
        NativeExeExists       = $false
    }

    if ($TestSafe -or $env:CCDI_TEST_MODE -eq "1") {
        Write-Log "INFO" "TestSafe: 跳过 fresh shell 验证"
        $result.Error = "skipped_test_safe"
        $result.Reason = "test_safe"

        # MOCK 支持
        if ($env:CCDI_MOCK_INSTALL_DECISION -eq "1" -and $env:CCDI_TEST_MODE -eq "1") {
            $mockFresh = if ($env:CCDI_MOCK_FRESH_SHELL) { $env:CCDI_MOCK_FRESH_SHELL } else { "fail" }
            if ($mockFresh -eq "ok") {
                return @{
                    Success = $true; Output = "2.1.178 (Claude Code)"; Error = ""; ExitCode = 0;
                    Version = "2.1.178 (Claude Code)"; Reason = "mock"; CommandPath = "C:\mock\claude.exe";
                    UserPathContainsNative = $true; NativeExeExists = $true
                }
            }
            return @{
                Success = $false; Output = ""; Error = "mock: fresh shell claude not found";
                ExitCode = 10; Version = $null; Reason = "mock"; CommandPath = "";
                UserPathContainsNative = $false; NativeExeExists = $false
            }
        }

        return $result
    }

    # --- 创建临时检测脚本和输出文件 ---
    $tempDir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
    $tempScript = Join-Path $tempDir "ccdi_fresh_shell_${PID}_$(Get-Random).ps1"
    $tempOut    = Join-Path $tempDir "ccdi_fresh_shell_out_${PID}_$(Get-Random).txt"
    $tempErr    = Join-Path $tempDir "ccdi_fresh_shell_err_${PID}_$(Get-Random).txt"

    $probeScript = @'
$ErrorActionPreference = "Stop"

$result = [ordered]@{
    Success               = $false
    Output                = ""
    Error                 = ""
    CommandPath           = ""
    UserPathContainsNative = $false
    NativeExeExists       = $false
}

try {
    $userProfile = [Environment]::GetFolderPath("UserProfile")
    $nativeBin   = Join-Path $userProfile ".local\bin"
    $nativeExe   = Join-Path $nativeBin "claude.exe"

    $userPath    = [Environment]::GetEnvironmentVariable("Path", "User")
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")

    $cleanPathParts = @()
    if ($userPath)    { $cleanPathParts += $userPath }
    if ($machinePath) { $cleanPathParts += $machinePath }
    $env:Path = ($cleanPathParts -join ";")

    $result.NativeExeExists = Test-Path $nativeExe

    if ($userPath) {
        $entries = $userPath -split ";" | ForEach-Object { $_.Trim().TrimEnd('\') } | Where-Object { $_ }
        $target = $nativeBin.Trim().TrimEnd('\')
        foreach ($entry in $entries) {
            if ($entry.ToLowerInvariant() -eq $target.ToLowerInvariant()) {
                $result.UserPathContainsNative = $true
                break
            }
        }
    }

    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $cmd) {
        $result.Error = "claude not found in reconstructed User+Machine PATH"
        $result | ConvertTo-Json -Compress
        exit 10
    }

    $cmdPath = if ($cmd.Source) { $cmd.Source } else { $cmd.Definition }
    $result.CommandPath = $cmdPath

    $versionOutput = & claude --version 2>&1
    $code = $LASTEXITCODE

    if ($code -eq 0 -and -not [string]::IsNullOrWhiteSpace(($versionOutput | Out-String))) {
        $result.Success = $true
        $result.Output = (($versionOutput | Out-String).Trim())
        $result | ConvertTo-Json -Compress
        exit 0
    }

    $result.Error = "claude --version failed, exit=$code, output=$(($versionOutput | Out-String).Trim())"
    $result | ConvertTo-Json -Compress
    exit 11
}
catch {
    $result.Error = "fresh shell probe exception: $($_.Exception.Message)"
    $result | ConvertTo-Json -Compress
    exit 20
}
'@

    try {
        # 写入临时 .ps1（UTF-8 no BOM）
        [System.IO.File]::WriteAllText($tempScript, $probeScript, (New-Object System.Text.UTF8Encoding($false)))

        # 解析 powershell.exe 完整路径，确保兼容性
        $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        if (-not (Test-Path $psExe)) { $psExe = "powershell.exe" }

        # 给 $tempScript 安全加引号，防止路径含空格时被错误拆分
        $quotedTempScript = ConvertTo-CommandLineArgument -Argument $tempScript
        $argumentLine = "-NoProfile -ExecutionPolicy Bypass -File $quotedTempScript"

        # 直接使用 Start-Process + powershell.exe -File，不通过 Invoke-CommandSafe / cmd.exe
        $proc = Start-Process -FilePath $psExe `
            -ArgumentList $argumentLine `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput $tempOut `
            -RedirectStandardError $tempErr

        Write-Log "DEBUG" "Test-ClaudeCommandInFreshShell: powershell probe started, psExe=$psExe, tempScript=$tempScript"

        # 等待子进程完成，最多 30 秒
        $finished = $proc.WaitForExit(30000)

        if (-not $finished) {
            # 超时：杀进程树
            $result.Reason = "timeout"
            $result.Error = "Fresh shell 验证超时（30 秒）"
            Write-Log "WARN" "Test-ClaudeCommandInFreshShell: 超时，杀进程树 PID=$($proc.Id)"

            try {
                $killResult = & taskkill.exe /PID $proc.Id /T /F 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "INFO" "已终止 fresh shell 进程树 PID=$($proc.Id): $killResult"
                }
                else {
                    if (-not $proc.HasExited) { $proc.Kill() }
                }
                $proc.WaitForExit(5000) | Out-Null
            }
            catch {
                Write-Log "WARN" "终止 fresh shell 进程异常: $_"
                try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
            }

            $result.ExitCode = -1
            return $result
        }

        $exitCode = $proc.ExitCode
        $result.ExitCode = $exitCode

        # 读取 stdout（应为 JSON）
        $jsonOutput = ""
        if (Test-Path $tempOut) {
            $jsonOutput = Get-Content $tempOut -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($null -eq $jsonOutput) { $jsonOutput = "" }
        }
        $stderrText = ""
        if (Test-Path $tempErr) {
            $stderrText = Get-Content $tempErr -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($null -eq $stderrText) { $stderrText = "" }
        }

        # 解析 JSON 输出
        $parsed = $null
        if (-not [string]::IsNullOrWhiteSpace($jsonOutput)) {
            try {
                $parsed = $jsonOutput.Trim() | ConvertFrom-Json
            }
            catch {
                Write-Log "WARN" "Test-ClaudeCommandInFreshShell: JSON 解析失败, stdout=$([System.Environment]::NewLine)$jsonOutput"
            }
        }

        if ($parsed) {
            $result.Success = [bool]$parsed.Success
            $result.Output = if ($parsed.Output) { [string]$parsed.Output } else { "" }
            $result.Error = if ($parsed.Error) { [string]$parsed.Error } else { "" }
            $result.CommandPath = if ($parsed.CommandPath) { [string]$parsed.CommandPath } else { "" }
            $result.UserPathContainsNative = if ($parsed.PSObject.Properties.Name -contains "UserPathContainsNative") {
                [bool]$parsed.UserPathContainsNative
            } else { $false }
            $result.NativeExeExists = if ($parsed.PSObject.Properties.Name -contains "NativeExeExists") {
                [bool]$parsed.NativeExeExists
            } else { $false }

            # 版本提取
            if ($result.Success -and $result.Output) {
                if ($result.Output -match '(\d+\.\d+\.\d+[^\s,]*)') {
                    $result.Version = $matches[1]
                }
                else {
                    $result.Version = $result.Output
                }
            }

            if ($result.Success) {
                $result.Reason = "success"
                Write-Log "INFO" "Test-ClaudeCommandInFreshShell: 成功 - Version=$($result.Version), CommandPath=$($result.CommandPath)"
            }
            else {
                $result.Reason = "probe_reported_failure"
                # 失败但 native 文件和 PATH 都就绪 → 不写 ERROR，写 INFO（避免误报）
                if ($result.NativeExeExists -and $result.UserPathContainsNative) {
                    Write-Log "INFO" "Test-ClaudeCommandInFreshShell: 失败但文件与 PATH 均已就绪 - ExitCode=$exitCode, Error=$($result.Error), NativeExeExists=$($result.NativeExeExists), UserPathContainsNative=$($result.UserPathContainsNative)"
                    $result.Reason = "fail_but_path_ok"
                }
                else {
                    Write-Log "WARN" "Test-ClaudeCommandInFreshShell: 失败 - ExitCode=$exitCode, Error=$($result.Error), NativeExeExists=$($result.NativeExeExists), UserPathContainsNative=$($result.UserPathContainsNative)"
                }
            }
        }
        else {
            # JSON 解析失败，用 stderr + exit code 作为诊断信息
            $result.Reason = "json_parse_failed"
            $result.Error = if ($stderrText.Trim()) {
                "stdout 非 JSON, stderr=$($stderrText.Trim())"
            }
            else {
                "stdout 非 JSON, exit=$exitCode"
            }
            Write-Log "WARN" "Test-ClaudeCommandInFreshShell: JSON 解析失败, exit=$exitCode, stderr=$($stderrText.Trim())"
        }
    }
    catch {
        $result.Error = "Fresh shell 验证异常: $($_.Exception.Message)"
        $result.Reason = "exception"
        Write-Log "ERROR" "Test-ClaudeCommandInFreshShell: $($result.Error)"
    }
    finally {
        # 清理临时文件
        foreach ($tmpPath in @($tempScript, $tempOut, $tempErr)) {
            if ($tmpPath -and (Test-Path $tmpPath)) {
                Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return $result
}

# ============================================================
# PATH 刷新
# ============================================================

function Refresh-CurrentProcessPath {
    <#
    .SYNOPSIS
        将 Machine 和 User 级别的 PATH 环境变量合并到当前进程。
        同时加入常见 node/npm 路径，防止 winget 安装后 PATH 未即时生效。
        用于 Native Install / npm / winget 安装后刷新 PATH。
    #>
    try {
        $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $combined = @()
        if ($userPath) { $combined += $userPath }
        if ($machinePath) { $combined += $machinePath }

        # 追加常见 node/npm 路径（winget 安装后可能尚未在注册表 PATH 中）
        $extraPaths = @()
        if ($env:ProgramFiles) {
            $extraPaths += Join-Path $env:ProgramFiles "nodejs"
        }
        if (${env:ProgramFiles(x86)}) {
            $extraPaths += Join-Path ${env:ProgramFiles(x86)} "nodejs"
        }
        if ($env:APPDATA) {
            $extraPaths += Join-Path $env:APPDATA "npm"
        }
        # Native Install 默认路径（Claude 官方安装到 %USERPROFILE%\.local\bin）
        $nativeClaudeBin = Join-Path (Get-UserProfilePath) ".local\bin"
        if (Test-Path $nativeClaudeBin) {
            $extraPaths += $nativeClaudeBin
        }
        foreach ($p in $extraPaths) {
            if ($p -and (Test-Path $p) -and $p -notin $combined) {
                $combined += $p
            }
        }

        $env:Path = ($combined -join ";") + ";" + $env:Path
        Write-Log "DEBUG" "PATH 已刷新（合并 Machine + User + 常见 node/npm + Native Install .local\bin 路径到当前进程）"
    }
    catch {
        Write-Log "WARN" "PATH 刷新失败: $_"
    }
}

# ============================================================
# npm.cmd 路径解析
# ============================================================

function Resolve-NpmCmdPath {
    <#
    .SYNOPSIS
        Windows 下强制解析 npm.cmd，避免 Get-Command npm 命中 npm.ps1。
        在 PowerShell 中 Get-Command npm 可能返回 npm.ps1（由 npm 包自身安装），
        .ps1 文件不能直接被 Start-Process 执行，会导致 "%1 is not a valid Win32 application"。
    .RETURNS
        包含 Found, Path, Source, Error 的 hashtable
    #>
    $result = @{
        Found  = $false
        Path   = $null
        Source = ""
        Error  = ""
    }

    # 1. 优先 Get-Command npm.cmd
    $npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($npmCmd) {
        $resolved = if ($npmCmd.Source) { $npmCmd.Source } else { $npmCmd.Definition }
        if ($resolved -and (Test-Path $resolved)) {
            $result.Found = $true
            $result.Path = $resolved
            $result.Source = "Get-Command npm.cmd"
            Write-Log "DEBUG" "Resolve-NpmCmdPath: 通过 Get-Command npm.cmd 找到: $resolved"
            return $result
        }
    }

    # 2. 检查常见安装路径
    $commonPaths = @()
    if ($env:ProgramFiles) {
        $commonPaths += Join-Path $env:ProgramFiles "nodejs\npm.cmd"
    }
    if (${env:ProgramFiles(x86)}) {
        $commonPaths += Join-Path ${env:ProgramFiles(x86)} "nodejs\npm.cmd"
    }
    if ($env:APPDATA) {
        $commonPaths += Join-Path $env:APPDATA "npm\npm.cmd"
    }

    foreach ($candidate in $commonPaths) {
        if ($candidate -and (Test-Path $candidate)) {
            $result.Found = $true
            $result.Path = $candidate
            $result.Source = "常见路径"
            Write-Log "DEBUG" "Resolve-NpmCmdPath: 通过常见路径找到: $candidate"
            return $result
        }
    }

    # 3. where.exe npm.cmd
    try {
        $whereResult = & where.exe npm.cmd 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($whereResult)) {
            $firstLine = ($whereResult | Select-Object -First 1).Trim()
            if ($firstLine -match '\.cmd$' -and (Test-Path $firstLine)) {
                $result.Found = $true
                $result.Path = $firstLine
                $result.Source = "where.exe"
                Write-Log "DEBUG" "Resolve-NpmCmdPath: 通过 where.exe 找到: $firstLine"
                return $result
            }
        }
    }
    catch {
        Write-Log "DEBUG" "Resolve-NpmCmdPath: where.exe npm.cmd 失败: $_"
    }

    # 4. 最后尝试 Get-Command npm（仅记录 npm.ps1 诊断信息，不返回 .ps1）
    $npmAny = Get-Command npm -ErrorAction SilentlyContinue
    if ($npmAny) {
        $anyPath = if ($npmAny.Source) { $npmAny.Source } else { $npmAny.Definition }
        if ($anyPath -match '\.ps1$') {
            Write-Log "INFO" "检测到 npm.ps1 ($anyPath)，但安装阶段不能直接执行 npm.ps1，将继续查找 npm.cmd。"
            $result.Error = "仅找到 npm.ps1 ($anyPath)，无法用于安装。Node.js 安装可能不完整或 PATH 未刷新。"
        }
        else {
            $result.Error = "未找到 npm.cmd，Get-Command npm 返回: $anyPath"
        }
    }
    else {
        $result.Error = "未找到 npm.cmd 或 npm 命令。请确认 Node.js 安装完整，且当前终端 PATH 已刷新。"
    }

    Write-Log "WARN" "Resolve-NpmCmdPath: $($result.Error)"
    return $result
}

function Test-CommandAvailable {
    <#
    .SYNOPSIS
        检测某个命令是否在 PATH 中可用
    .PARAMETER CommandName
        命令名称（如 "git", "code", "claude"）
    .RETURNS
        命令可用返回 $true
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )

    try {
        $null = Get-Command $CommandName -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Invoke-CommandSafe {
    <#
    .SYNOPSIS
        安全执行外部命令，捕获输出和错误
    .PARAMETER Command
        命令（如 "claude"）
    .PARAMETER Arguments
        命令参数数组
    .PARAMETER LogTimeoutAsWarn
        超时时使用 WARN 日志级别而非 ERROR。用于可选命令（如 WSL 检测），避免日志噪音。
    .RETURNS
        包含 Success, ExitCode, Output, Error 的哈希表
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 60,
        [string]$ProgressMessage = "",
        [int]$ProgressIntervalSec = 20,
        [switch]$LogTimeoutAsWarn
    )

    $result = @{
        Success  = $false
        ExitCode = -1
        Output   = ""
        Error    = ""
    }

    try {
        $startFile = $Command
        $startArguments = $Arguments
        $commandInfo = $null
        $candidates = @(Get-Command $Command -All -ErrorAction SilentlyContinue)
        if ($candidates.Count -gt 0) {
            $commandInfo = $candidates |
                Where-Object {
                    $_.CommandType -eq "Application" -and
                    $_.Source -and
                    ([System.IO.Path]::GetExtension($_.Source).ToLowerInvariant() -in @(".exe", ".com", ".cmd", ".bat"))
                } |
                Select-Object -First 1

            if (-not $commandInfo) {
                $commandInfo = $candidates | Select-Object -First 1
            }

            $resolvedPath = if ($commandInfo.Source) { $commandInfo.Source } else { $commandInfo.Definition }
            if (-not [string]::IsNullOrWhiteSpace($resolvedPath)) {
                $startFile = $resolvedPath
            }
        }

        # Windows PowerShell 5.1 may return a blank Start-Process ExitCode,
        # and npm often resolves to a .cmd shim. Run through cmd.exe and
        # capture stdout/stderr/exit code explicitly.
        $tempDir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
        $tmpOut = Join-Path $tempDir "ccdi_stdout_${PID}_$(Get-Random).tmp"
        $tmpErr = Join-Path $tempDir "ccdi_stderr_${PID}_$(Get-Random).tmp"
        $tmpExit = Join-Path $tempDir "ccdi_exit_${PID}_$(Get-Random).tmp"

        $commandLine = ConvertTo-CommandLine -Arguments (@($startFile) + $startArguments)
        $innerCommand = "$commandLine > $(ConvertTo-CommandLineArgument -Argument $tmpOut) 2> $(ConvertTo-CommandLineArgument -Argument $tmpErr) & echo !ERRORLEVEL! > $(ConvertTo-CommandLineArgument -Argument $tmpExit)"
        $cmdExe = if ($env:ComSpec) { $env:ComSpec } else { "cmd.exe" }
        $argumentLine = "/d /v:on /s /c `"$innerCommand`""

        $proc = Start-Process -FilePath $cmdExe -ArgumentList $argumentLine -NoNewWindow -PassThru

        Write-Log "DEBUG" "Invoke-CommandSafe: resolved=$startFile, cwd=$(Get-Location), args=$(ConvertTo-SafeLogText -Text $argumentLine), cmdPid=$($proc.Id)"

        # 等待进程完成，设置超时；长命令可选择性输出心跳提示。
        $finished = $false
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        $nextProgressAt = (Get-Date).AddSeconds([Math]::Max(1, $ProgressIntervalSec))

        while (-not $finished) {
            $finished = $proc.WaitForExit(1000)
            if ($finished) {
                break
            }

            $now = Get-Date
            if ($now -ge $deadline) {
                break
            }

            if ($ProgressMessage -and $now -ge $nextProgressAt) {
                Write-Info $ProgressMessage
                $nextProgressAt = $now.AddSeconds([Math]::Max(1, $ProgressIntervalSec))
            }
        }

        if (-not $finished) {
            # 超时：先读取临时文件内容用于诊断，再杀进程树，最后清理
            if ($LogTimeoutAsWarn) {
                Write-Log "WARN" "命令超时 (${TimeoutSec}s): $Command $(ConvertTo-SafeLogText -Text $argumentLine)"
            }
            else {
                Write-Log "ERROR" "命令超时 (${TimeoutSec}s): $Command $(ConvertTo-SafeLogText -Text $argumentLine)"
            }

            # 超时后先保存临时文件内容，再清理
            if (Test-Path $tmpOut) {
                try {
                    $partialOut = Get-Content $tmpOut -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if (-not [string]::IsNullOrWhiteSpace($partialOut)) {
                        $maxPartialLen = 4000
                        $result.Output = if ($partialOut.Length -gt $maxPartialLen) {
                            $partialOut.Substring(0, $maxPartialLen) + "`n...[截断]"
                        } else { $partialOut }
                        Write-Log "INFO" "超时部分 stdout ($($partialOut.Length) bytes): $(if ($partialOut.Length -gt 500) { ConvertTo-SafeLogText -Text ($partialOut.Substring(0, 500)) + '...' } else { ConvertTo-SafeLogText -Text $partialOut })"
                    }
                }
                catch { Write-Log "WARN" "读取超时 stdout 失败: $_" }
            }
            if (Test-Path $tmpErr) {
                try {
                    $partialErr = Get-Content $tmpErr -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if (-not [string]::IsNullOrWhiteSpace($partialErr)) {
                        $maxPartialLen = 4000
                        $result.Error = if ($partialErr.Length -gt $maxPartialLen) {
                            $partialErr.Substring(0, $maxPartialLen) + "`n...[截断]"
                        } else { $partialErr }
                        Write-Log "INFO" "超时部分 stderr ($($partialErr.Length) bytes): $(if ($partialErr.Length -gt 500) { ConvertTo-SafeLogText -Text ($partialErr.Substring(0, 500)) + '...' } else { ConvertTo-SafeLogText -Text $partialErr })"
                    }
                }
                catch { Write-Log "WARN" "读取超时 stderr 失败: $_" }
            }

            if ([string]::IsNullOrWhiteSpace($result.Error)) {
                $result.Error = "命令执行超时 (${TimeoutSec}秒): $Command"
            }

            # 杀进程树：优先 taskkill /T /F，fallback 到 Stop-Process
            try {
                if (-not $proc.HasExited) {
                    $procId = $proc.Id
                    Write-Log "INFO" "正在用 taskkill /T /F 终止进程树 PID=$procId"
                    $killResult = & taskkill.exe /PID $procId /T /F 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log "INFO" "已终止进程树 PID=$($procId): $killResult"
                    }
                    else {
                        Write-Log "WARN" "taskkill 返回非零 ($LASTEXITCODE): $killResult, 尝试 Stop-Process fallback"
                        # 查找子进程并逐级终止
                        $childProcs = Get-CimInstance Win32_Process -Filter "ParentProcessId=$procId" -ErrorAction SilentlyContinue
                        if (-not $childProcs) {
                            $childProcs = Get-WmiObject Win32_Process -Filter "ParentProcessId=$procId" -ErrorAction SilentlyContinue
                        }
                        if ($childProcs) {
                            foreach ($child in $childProcs) {
                                try {
                                    Stop-Process -Id $child.ProcessId -Force -ErrorAction Stop
                                    Write-Log "INFO" "已终止子进程 PID=$($child.ProcessId)"
                                }
                                catch {
                                    Write-Log "WARN" "终止子进程失败 PID=$($child.ProcessId): $_"
                                }
                            }
                        }
                        Stop-Process -Id $procId -Force -ErrorAction Stop
                        Write-Log "INFO" "已通过 Stop-Process 终止父进程 PID=$procId"
                    }
                    $proc.WaitForExit(5000) | Out-Null
                }
            }
            catch {
                Write-Log "WARN" "终止超时进程树时发生异常: $_"
                try {
                    if (-not $proc.HasExited) {
                        $proc.Kill()
                        $proc.WaitForExit(5000) | Out-Null
                    }
                }
                catch {
                    Write-Log "ERROR" "fallback Kill 也失败: $_"
                }
            }

            $result.Success = $false
            # 清理临时文件
            foreach ($tmpPath in @($tmpOut, $tmpErr, $tmpExit)) {
                if ($tmpPath -and (Test-Path $tmpPath)) {
                    Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
                }
            }
            return $result
        }

        if (Test-Path $tmpExit) {
            $exitText = (Get-Content $tmpExit -Raw -ErrorAction SilentlyContinue).Trim()
            if ($exitText -match '^-?\d+$') {
                $result.ExitCode = [int]$exitText
            }
        }
        $result.Success = ($result.ExitCode -eq 0)

        if (Test-Path $tmpOut) {
            $result.Output = Get-Content $tmpOut -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($null -eq $result.Output) { $result.Output = "" }
        }
        if (Test-Path $tmpErr) {
            $result.Error = Get-Content $tmpErr -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($null -eq $result.Error) { $result.Error = "" }
        }

        foreach ($tmpPath in @($tmpOut, $tmpErr, $tmpExit)) {
            if ($tmpPath -and (Test-Path $tmpPath)) {
                Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        $result.Error = $_.Exception.Message
        Write-Log "ERROR" "命令执行异常: $Command $Arguments, 错误: $($_.Exception.Message)"
    }

    return $result
}

function ConvertTo-CommandLine {
    <#
    .SYNOPSIS
        将参数数组转换为兼容 Windows PowerShell 5.1 Start-Process 的命令行。
    #>
    param([string[]]$Arguments = @())

    if ($null -eq $Arguments -or $Arguments.Count -eq 0) {
        return ""
    }

    $quoted = @()
    foreach ($arg in $Arguments) {
        $quoted += ConvertTo-CommandLineArgument -Argument $arg
    }

    return ($quoted -join " ")
}

function ConvertTo-CommandLineArgument {
    param([AllowNull()][string]$Argument)

    if ($null -eq $Argument) {
        return '""'
    }

    if ($Argument.Length -eq 0) {
        return '""'
    }

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $result = New-Object System.Text.StringBuilder
    [void]$result.Append('"')
    $backslashes = 0

    foreach ($char in $Argument.ToCharArray()) {
        if ($char -eq '\') {
            $backslashes++
            continue
        }

        if ($char -eq '"') {
            [void]$result.Append(('\' * ($backslashes * 2 + 1)))
            [void]$result.Append('"')
        }
        else {
            if ($backslashes -gt 0) {
                [void]$result.Append(('\' * $backslashes))
            }
            [void]$result.Append($char)
        }

        $backslashes = 0
    }

    if ($backslashes -gt 0) {
        [void]$result.Append(('\' * ($backslashes * 2)))
    }
    [void]$result.Append('"')

    return $result.ToString()
}

# ============================================================
# 配置文件内容脱敏函数
# ============================================================

function Get-SafeConfigContent {
    <#
    .SYNOPSIS
        读取配置文件内容，但脱敏 API Key
    .PARAMETER FilePath
        配置文件路径
    .RETURNS
        脱敏后的 JSON 字符串
    #>
    param([string]$FilePath)

    $json = Read-JsonFileSafe -FilePath $FilePath
    if ($null -eq $json) {
        return "(文件不存在或格式无效)"
    }

    # 克隆对象并脱敏
    $clone = $json | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $cloneProps = @($clone.PSObject.Properties | ForEach-Object { $_.Name })
    if (($cloneProps -contains "env") -and $null -ne $clone.env) {
        $cloneEnvProps = @($clone.env.PSObject.Properties | ForEach-Object { $_.Name })
        if ($cloneEnvProps -contains "ANTHROPIC_AUTH_TOKEN") {
            $clone.env.ANTHROPIC_AUTH_TOKEN = Mask-ApiKey -Key $clone.env.ANTHROPIC_AUTH_TOKEN
        }
    }

    return ($clone | ConvertTo-Json -Depth 10)
}

# ============================================================
# 报告脱敏函数
# ============================================================

function Get-UserNameForSanitize {
    <#
    .SYNOPSIS
        获取当前用户名（用于报告脱敏），支持 CCDI_TEST_USERNAME 覆盖
    #>
    if ($env:CCDI_TEST_MODE -eq "1" -and $env:CCDI_TEST_USERNAME) {
        return $env:CCDI_TEST_USERNAME
    }
    return $env:USERNAME
}

function Sanitize-PathForReport {
    <#
    .SYNOPSIS
        将报告中的路径替换为环境变量占位符
    .PARAMETER Text
        原始文本
    .RETURNS
        脱敏后的文本
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    $result = $Text
    $userName = Get-UserNameForSanitize

    $pathReplacements = @()

    if ($env:CCDI_TEST_MODE -eq "1") {
        if (-not [string]::IsNullOrWhiteSpace($env:CCDI_TEST_USERPROFILE)) {
            $pathReplacements += [pscustomobject]@{
                Path = $env:CCDI_TEST_USERPROFILE
                Mask = "%USERPROFILE%"
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($env:CCDI_TEST_DESKTOP)) {
            $pathReplacements += [pscustomobject]@{
                Path = $env:CCDI_TEST_DESKTOP
                Mask = "%USERPROFILE%\Desktop"
            }
        }
    }

    if (Get-Command Get-CcdiProjectRoot -ErrorAction SilentlyContinue) {
        $projectRoot = Get-CcdiProjectRoot
        if (-not [string]::IsNullOrWhiteSpace($projectRoot)) {
            $pathReplacements += [pscustomobject]@{
                Path = $projectRoot
                Mask = "%PROJECT_DIR%"
            }
        }
    }

    foreach ($entry in $pathReplacements) {
        $path = ([string]$entry.Path).TrimEnd([char[]]@('\', '/'))
        $mask = [string]$entry.Mask
        if ([string]::IsNullOrWhiteSpace($path)) { continue }

        $result = $result.Replace("$path\", "$mask\")
        $result = $result.Replace("$path/", "$mask/")
        $result = $result.Replace($path, $mask)

        $altSlash = $path.Replace('\', '/')
        $result = $result.Replace("$altSlash/", "$mask/")
        $result = $result.Replace($altSlash, $mask)
    }

    if (-not [string]::IsNullOrWhiteSpace($userName)) {
        # C:\Users\具体用户名\ → %USERPROFILE%\
        $result = $result -replace [regex]::Escape("C:\Users\$userName\"), '%USERPROFILE%\'
        $result = $result -replace [regex]::Escape("C:\Users\$userName"), '%USERPROFILE%'
        $result = $result -replace [regex]::Escape("C:\\Users\\$userName\\"), '%USERPROFILE%\'
        $result = $result -replace [regex]::Escape("C:\\Users\\$userName"), '%USERPROFILE%'

        # /home/具体用户名/ → ~/
        $result = $result -replace "/home/$userName/", '~/'
        $result = $result -replace "/home/$userName", '~'

        # WSL UNC / pushd mapped paths may appear in native Windows reports.
        $result = $result -replace [regex]::Escape("\\wsl.localhost\Ubuntu\home\$userName\"), '~\'
        $result = $result -replace [regex]::Escape("\\wsl.localhost\Ubuntu\home\$userName"), '~'
        $mappedHomeWithSlash = '(?i)[A-Z]:\\home\\' + [regex]::Escape($userName) + '\\'
        $mappedHome = '(?i)[A-Z]:\\home\\' + [regex]::Escape($userName)
        $result = $result -replace $mappedHomeWithSlash, '~\'
        $result = $result -replace $mappedHome, '~'

        # Remove standalone username fragments that remain after path masking.
        $result = $result -replace ('(?i)(?<![A-Za-z0-9_-])' + [regex]::Escape($userName) + '(?![A-Za-z0-9_-])'), '<USER>'
    }

    return $result
}

function Sanitize-ProxyUrl {
    <#
    .SYNOPSIS
        脱敏代理 URL 中的用户名密码。
    .PARAMETER Text
        原始文本（可能包含代理 URL）
    .RETURNS
        脱敏后的文本
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    $result = $Text

    # http://user:pass@host:port -> http://<AUTH>@host:port
    $result = $result -replace '(?i)(https?://)[^/@\s:]+:[^/@\s]+@', '$1<AUTH>@'

    # socks5://user:pass@host:port -> socks5://<AUTH>@host:port
    $result = $result -replace '(?i)(socks5?h?://)[^/@\s:]+:[^/@\s]+@', '$1<AUTH>@'

    return $result
}

function ConvertTo-SafeLogText {
    <#
    .SYNOPSIS
        对日志输出文本进行脱敏：API Key + 代理密码。
        调用方仍可获取原始值用于逻辑判断，仅日志写入时调用此函数。
    .PARAMETER Text
        原始文本
    .RETURNS
        脱敏后文本
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    $result = $Text
    $result = Sanitize-SecretLikeText -Text $result
    $result = Sanitize-ProxyUrl -Text $result
    return $result
}

function Sanitize-SecretLikeText {
    <#
    .SYNOPSIS
        脱敏文本中的疑似 API Key 和 Token
    .PARAMETER Text
        原始文本
    .RETURNS
        脱敏后的文本
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    $result = $Text

    # 脱敏完整 DeepSeek Key: sk-[A-Za-z0-9]{20,}
    $keyPattern = 'sk-[A-Za-z0-9]{20,}'
    $matches = [regex]::Matches($result, $keyPattern)
    foreach ($m in $matches) {
        $result = $result.Replace($m.Value, (Mask-ApiKey -Key $m.Value))
    }

    # 脱敏 env 变量值中的 Key（如 ANTHROPIC_AUTH_TOKEN=sk-xxx）
    $tokenPatterns = @(
        'ANTHROPIC_AUTH_TOKEN["\s:=]+(sk-[A-Za-z0-9]+)',
        'DEEPSEEK_API_KEY["\s:=]+(sk-[A-Za-z0-9]+)',
        'CCDI_API_KEY["\s:=]+(sk-[A-Za-z0-9]+)',
        'x-api-key["\s:=]+(sk-[A-Za-z0-9]+)',
        'Authorization["\s:=]+Bearer\s+(sk-[A-Za-z0-9]+)'
    )

    foreach ($pattern in $tokenPatterns) {
        $tokenMatches = [regex]::Matches($result, $pattern)
        foreach ($tm in $tokenMatches) {
            if ($tm.Groups.Count -gt 1) {
                $fullMatch = $tm.Groups[0].Value
                $keyPart = $tm.Groups[1].Value
                $masked = $fullMatch.Replace($keyPart, (Mask-ApiKey -Key $keyPart))
                $result = $result.Replace($fullMatch, $masked)
            }
        }
    }

    # 代理 URL 脱敏
    $result = Sanitize-ProxyUrl -Text $result

    return $result
}

function Sanitize-ReportText {
    <#
    .SYNOPSIS
        综合脱敏报告文本：路径 + 密钥
    .PARAMETER Text
        原始报告文本
    .RETURNS
        完全脱敏后的文本（适合分享）
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    $result = $Text
    $result = Sanitize-PathForReport -Text $result
    $result = Sanitize-SecretLikeText -Text $result

    return $result
}

# ============================================================
# 诊断报告输出
# ============================================================

function Write-DiagnosticReports {
    <#
    .SYNOPSIS
        写入诊断报告（分享版 + 可选完整版）
    .PARAMETER ReportLines
        报告行数组（ArrayList 或 string[]）
    .PARAMETER ScriptDir
        项目根目录
    .PARAMETER Timestamp
        时间戳字符串
    .RETURNS
        包含 SharePath, HistoryPath, FullPath 的哈希表
    #>
    param(
        [Parameter(Mandatory = $true)]
        $ReportLines,
        [Parameter(Mandatory = $true)]
        [string]$ScriptDir,
        [string]$Timestamp = $null,
        [bool]$IncludeFullReport = $true
    )

    if (-not $Timestamp) {
        $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $reportContent = ($ReportLines -join "`r`n")

    $result = @{
        SharePath   = $null
        HistoryPath = $null
        FullPath    = $null
    }

    # 确保 reports 目录存在
    $reportsDir = Join-Path $ScriptDir "reports"
    if (-not (Test-Path $reportsDir)) {
        New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
    }

    # 1. 分享版报告（脱敏后）
    $shareContent = Sanitize-ReportText -Text $reportContent

    # report.txt（项目根目录）
    $shareRootPath = Join-Path $ScriptDir "report.txt"
    [System.IO.File]::WriteAllText($shareRootPath, $shareContent, $utf8NoBom)
    $result.SharePath = $shareRootPath

    # reports/report-YYYYMMDD-HHMMSS.txt（分享版历史）
    $historyPath = Join-Path $reportsDir "report-$Timestamp.txt"
    [System.IO.File]::WriteAllText($historyPath, $shareContent, $utf8NoBom)
    $result.HistoryPath = $historyPath

    # 2. 本地完整版（轻度脱敏：仅脱敏 API Key，保留路径）
    if ($IncludeFullReport) {
        $fullContent = Sanitize-SecretLikeText -Text $reportContent
        $fullPath = Join-Path $reportsDir "full-report-$Timestamp.txt"
        [System.IO.File]::WriteAllText($fullPath, $fullContent, $utf8NoBom)
        $result.FullPath = $fullPath
    }

    $fullLogText = if ($result.FullPath) { $result.FullPath } else { "(ShareSafe skipped)" }
    Write-Log "INFO" "诊断报告已保存: 分享版=$shareRootPath, 完整版=$fullLogText"
    return $result
}

# ============================================================
# WSL 路径转换
# ============================================================

function Convert-WindowsPathToWslPath {
    <#
    .SYNOPSIS
        使用 wsl wslpath 将 Windows 路径转换为 WSL 路径。
        不使用手写字符串替换。
    .PARAMETER WindowsPath
        Windows 文件系统路径
    .RETURNS
        WSL 路径字符串，失败返回 $null
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowsPath
    )

    # 安全检查：路径中包含危险字符时拒绝处理
    if ($WindowsPath -match "['`n`r]") {
        Write-Log "WARN" "WSL 路径转换: Windows 路径包含单引号或换行符，拒绝处理"
        return $null
    }

    try {
        $result = Invoke-CommandSafe -Command "wsl" -Arguments @(
            "wslpath", "-a", $WindowsPath
        )

        if ($result.Success -and -not [string]::IsNullOrWhiteSpace($result.Output)) {
            $wslPath = $result.Output.Trim()
            Write-Log "INFO" "WSL 路径转换: $WindowsPath -> $wslPath"
            return $wslPath
        }
        else {
            Write-Log "WARN" "wslpath 转换失败: $($result.Error)"
            return $null
        }
    }
    catch {
        Write-Log "ERROR" "WSL 路径转换异常: $_"
        return $null
    }
}

function Test-WslPathSafe {
    <#
    .SYNOPSIS
        检查 Windows 路径是否可以安全地传递给 WSL 命令
    .PARAMETER WindowsPath
        Windows 路径
    .RETURNS
        是否安全
    #>
    param([string]$WindowsPath)

    if ($WindowsPath -match "'") {
        Write-Warning "Windows 路径包含单引号，无法安全传递给 WSL 命令。"
        Write-Warning "请改用方式 A：在 WSL 终端中手动运行。"
        return $false
    }

    if ($WindowsPath -match "`n|`r") {
        Write-Warning "Windows 路径包含换行符，无法安全传递。"
        return $false
    }

    return $true
}

# ============================================================
# 文本清洗函数
# ============================================================

function Remove-AnsiEscape {
    <#
    .SYNOPSIS
        清除文本中的 ANSI escape 序列（颜色、光标、spinner 等控制符）。
    .PARAMETER Text
        原始文本
    .RETURNS
        清除 ANSI 序列后的文本
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    $result = $Text

    # 通用 CSI 序列: ESC [ 参数... 中间字节... 最终字节
    # 覆盖 颜色/SGR (m), 光标移动 (ABCDEFGH), 清屏 (J,K), 模式设置 (h,l), 等
    $result = $result -replace '\x1B\[[0-?]*[ -/]*[@-~]', ''

    # OSC 序列（如 OSC...ST 的超链接/标题设置）
    $result = $result -replace '\x1B\][^\x07]*(\x07|\x1B\\)', ''

    # 其他非 CSI escape 序列（ESC 后跟单个可打印字符）
    $result = $result -replace '\x1B[@-Z\\-_]', ''

    # 残留的单独 ESC 字符
    $result = $result -replace '\x1B', ''

    return $result
}

function Remove-ControlChars {
    <#
    .SYNOPSIS
        清除不可打印控制字符，保留换行、回车、制表符。
    .PARAMETER Text
        原始文本
    .RETURNS
        清洗后的文本
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    $result = $Text

    # 清除 \x00-\x08, \x0B-\x0C, \x0E-\x1F 范围的控制字符
    # 保留 \x09 (Tab), \x0A (LF), \x0D (CR)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $result.ToCharArray()) {
        $code = [int]$ch
        if ($code -eq 9 -or $code -eq 10 -or $code -eq 13) {
            [void]$sb.Append($ch)
        }
        elseif ($code -lt 32) {
            # 跳过其他控制字符
            continue
        }
        elseif ($code -eq 0x7F) {
            # DEL 字符
            continue
        }
        else {
            [void]$sb.Append($ch)
        }
    }

    return $sb.ToString()
}

function Test-Mojibake {
    <#
    .SYNOPSIS
        检测文本中是否包含疑似乱码字符（如 鈹/鉁/鈥/鈫/Hr,g 等）。
    .PARAMETER Text
        要检测的文本
    .RETURNS
        包含 HasMojibake, MojibakeLines 的哈希表
    #>
    param([string]$Text)

    $result = @{
        HasMojibake    = $false
        MojibakeLines  = @()
        Confidence     = 0
    }

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $result
    }

    # 已知乱码特征字符（UTF-8 通过 GBK/ANSI 错误解码时的典型产物）
    # 注意：不包含单独 "斤" "拷"，避免误伤 "公斤" "拷贝" 等正常中文
    $mojibakeChars = @(
        '鈹', '鉁', '鈥', '鈫', '銆', '鈩', '鉂', '鈽',
        '輟', '軻', '錐', '鏍', '鏋',
        '鈧', '鋨', '鉃', '銐', '銓', '鋏'
    )

    # 乱码组合模式（"锟斤拷" 是 UTF-8->GBK 二次编码的典型产物）
    $mojibakeCompounds = @(
        '锟斤拷', '锟斤', '斤拷'
    )

    # 疑似乱码模式（英文+逗号连在一起无空格，如 "Hr,g"）
    $mojibakePatterns = @(
        '[A-Z][a-z],[a-z]',   # 如 Hr,g
        '[A-Z][a-z],[A-Z]',   # 如 Wg,t
        '\?[A-Za-z]{2,}\?'    # 如 ?OK?
    )

    $lines = $Text -split "`n"
    $suspectLines = [System.Collections.ArrayList]::new()

    foreach ($line in $lines) {
        $isSuspicious = $false

        # 检查乱码字符（单字符特征）
        foreach ($char in $mojibakeChars) {
            if ($line.Contains($char)) {
                $isSuspicious = $true
                break
            }
        }

        # 检查乱码组合模式（如 "锟斤拷" 不会误伤单独的 "公斤" "拷贝"）
        if (-not $isSuspicious) {
            foreach ($compound in $mojibakeCompounds) {
                if ($line.Contains($compound)) {
                    $isSuspicious = $true
                    break
                }
            }
        }

        # 检查乱码模式
        if (-not $isSuspicious) {
            foreach ($pattern in $mojibakePatterns) {
                if ($line -match $pattern) {
                    $isSuspicious = $true
                    break
                }
            }
        }

        # 检查高比例非 ASCII 但也不是合法中文/日文的行
        if (-not $isSuspicious) {
            $nonAscii = 0
            $total = $line.Length
            if ($total -gt 0) {
                foreach ($ch in $line.ToCharArray()) {
                    if ([int]$ch -gt 127) { $nonAscii++ }
                }
                # 超过 60% 非 ASCII 且不匹配常见中文字符范围
                # 使用显式 Unicode 范围替代 \p{IsCJK...} 命名属性，
                # 避免 PowerShell 5.1 / .NET Framework 不支持导致崩溃。
                if ($nonAscii -gt ($total * 0.6)) {
                    $hasValidCJK = $line -match '[⺀-⻿　-〿぀-ゟ゠-ヿㇰ-ㇿ㐀-䶿一-鿿豈-﫿︐-︟︰-﹏＀-￯]'
                    if (-not $hasValidCJK) {
                        $isSuspicious = $true
                    }
                }
            }
        }

        if ($isSuspicious) {
            [void]$suspectLines.Add($line)
        }
    }

    $result.MojibakeLines = $suspectLines
    $result.HasMojibake = ($suspectLines.Count -gt 0)
    $result.Confidence = if ($suspectLines.Count -gt 3) { 2 } elseif ($suspectLines.Count -gt 0) { 1 } else { 0 }

    return $result
}

function Repair-OrSuppressMojibake {
    <#
    .SYNOPSIS
        对疑似乱码文本尝试提取有效信息，提取不到则返回占位说明。
    .PARAMETER Text
        原始文本
    .PARAMETER FallbackMessage
        提取不到有效信息时的占位消息
    .RETURNS
        清洗后的文本或占位消息
    #>
    param(
        [string]$Text,
        [string]$FallbackMessage = "[WARN] 外部命令输出存在编码异常，已隐藏原始内容；请查看日志或重新运行诊断。"
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $mojibakeCheck = Test-Mojibake -Text $Text

    if (-not $mojibakeCheck.HasMojibake) {
        return $Text
    }

    # 尝试从乱码中提取有效信息（版本号、路径、英文单词等）
    $extracted = [System.Collections.ArrayList]::new()

    # 提取版本号（如 1.2.3, v2.1.177）
    $versionMatches = [regex]::Matches($Text, '\b(v?\d+\.\d+\.\d+[^\s,]*)')
    foreach ($m in $versionMatches) {
        [void]$extracted.Add("Version: $($m.Value)")
    }

    # 提取平台信息
    if ($Text -match '(win32|linux|darwin)[-_]\w+') {
        [void]$extracted.Add("Platform: $($matches[0])")
    }

    # 提取路径（Windows 和 Unix 路径）
    $pathMatches = [regex]::Matches($Text, '([A-Za-z]:[\\/][^\s,;]+|/[^\s,;]+/[^\s,;]+)')
    $pathCount = 0
    foreach ($m in $pathMatches) {
        if ($pathCount -ge 3) { break }
        [void]$extracted.Add("Path: $($m.Value)")
        $pathCount++
    }

    # 提取 Search 状态
    if ($Text -match 'Search[:\s]*(OK|FAIL|WARN|ERROR)') {
        [void]$extracted.Add("Search: $($matches[1])")
    }

    # 提取 "OK" / "FAIL" 状态指示
    if ($Text -match '(?:^|\n)\s*(OK|FAIL|PASS|ERROR)\s*[:|-]') {
        [void]$extracted.Add("Status: $($matches[1])")
    }

    if ($extracted.Count -gt 0) {
        $cleaned = "--- 从输出中提取的关键信息 ---`n"
        $cleaned += ($extracted -join "`n")
        $cleaned += "`n--- 原始输出包含编码异常，以上为可解析部分 ---"
        return $cleaned
    }

    # 完全无法解析时返回安全的占位信息
    return $FallbackMessage
}

function Normalize-ExternalCommandOutput {
    <#
    .SYNOPSIS
        对外部命令输出进行标准化清洗：去 ANSI → 去控制字符 → 修复乱码。
    .PARAMETER Text
        原始命令输出
    .PARAMETER MaxLength
        清洗后最大长度，默认 8000 字符。超出部分截断并标记。
    .RETURNS
        标准化后的文本
    #>
    param(
        [string]$Text,
        [int]$MaxLength = 8000
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $cleaned = $Text
    $cleaned = Remove-AnsiEscape -Text $cleaned
    $cleaned = Remove-ControlChars -Text $cleaned
    $cleaned = Repair-OrSuppressMojibake -Text $cleaned

    # 合并连续空行（超过 3 个连续空行 → 合并为 2 个）
    $cleaned = $cleaned -replace "(\r?\n){4,}", "`n`n`n"

    # 长度限制
    if ($cleaned.Length -gt $MaxLength) {
        $cleaned = $cleaned.Substring(0, $MaxLength) + "`n...[输出已截断，完整内容见日志]"
    }

    return $cleaned
}

function Remove-ProgressNoiseLines {
    <#
    .SYNOPSIS
        v1.3.3 UX: 过滤进度 spinner 噪音行。
        移除单独由 - \ | / 组成的行（安装器进度符号），保留所有有效内容。
    .PARAMETER Text
        原始文本
    .RETURNS
        过滤 spinner 噪音后的文本
    #>
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $lines = $Text -split "`r?`n"
    $filtered = foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^[\\|/\-]$') {
            continue
        }
        $line
    }
    return ($filtered -join "`r`n")
}

function Remove-PowerShellTerminatingNoiseLines {
    <#
    .SYNOPSIS
        v1.3.3 UX: 过滤 PowerShell 运行时自动吐出的 PS>TerminatingError(...) 噪音行。
        保留 [ERROR]/[WARN] 等实际日志，只移除 PS>TerminatingError 前缀的噪音。
    .PARAMETER Text
        原始文本
    .RETURNS
        过滤后的文本
    #>
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }

    $lines = $Text -split "`r?`n"
    $filtered = foreach ($line in $lines) {
        if ($line -match '^PS>TerminatingError\(') {
            continue
        }
        $line
    }
    return ($filtered -join "`r`n")
}

function Convert-ToSafeReportText {
    <#
    .SYNOPSIS
        综合报告安全转换：脱敏 + 清洗 + 过滤内部字段。
        用于生成可安全分享的报告内容。
    .PARAMETER Text
        原始报告文本
    .RETURNS
        完全安全化的报告文本
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    $result = $Text

    # 1. 路径和 API Key 脱敏（复用已有函数）
    $result = Sanitize-ReportText -Text $result

    # 1b. 代理 URL 脱敏（http://user:pass@ 和 socks5://user:pass@）
    $result = Sanitize-ProxyUrl -Text $result

    # 2. 清除 ANSI escape 序列（防止报告中出现控制符）
    $result = Remove-AnsiEscape -Text $result

    # 3. 清除不可打印控制字符
    $result = Remove-ControlChars -Text $result

    # 3b. 过滤进度 spinner 噪音行（单独的 - \ | / 等无意义字符行）
    $result = Remove-ProgressNoiseLines -Text $result

    # 3c. 过滤 PS>TerminatingError 噪音行
    $result = Remove-PowerShellTerminatingNoiseLines -Text $result

    # 4. 过滤内部字段（GrowthBook, OAuth, feature flag 等）
    $internalFieldPatterns = @(
        '(?i)GrowthBook[:\s]+\S+',
        '(?i)feature[_\s]flag[:\s]+\S+',
        '(?i)OAuth[_\s]token[:\s]+\S+',
        '(?i)subscriber[_\s]auth[:\s]+\S+',
        '(?i)tengu_ccr_bridge[:\s]+\S+',
        '(?i)organization[_\s]UUID[:\s]+[a-f0-9-]+',
        '(?i)telemetryDisabledBy[:\s]+\S+',
        '(?i)DISABLE_GROWTHBOOK[:\s]+\S+',
        '(?i)growthbook[_\s]',
        '(?i)ccr_bridge[:\s]+\S+',
        '(?i)authToken[:\s]+\S+',
        '(?i)subscriberId[:\s]+\S+',
        '(?i)orgId[:\s]+\S+',
        '(?i)clientId[:\s]+\S+'
    )

    foreach ($pattern in $internalFieldPatterns) {
        $result = $result -replace $pattern, '[内部字段已过滤]'
    }

    # 5. 过滤疑似乱码行（兼容 CRLF/LF 换行）
    $lines = $result -split "\r?\n"
    $safeLines = [System.Collections.ArrayList]::new()
    # 单字符乱码特征（不包含 斤/拷）
    $mojibakeChars = @('鈹', '鉁', '鈥', '鈫', '銆', '鈩', '鉂', '鈽', '輟', '鏍')
    # 乱码组合（"锟斤拷" 不会误伤正常 "拷贝" "公斤"）
    $mojibakeCompounds = @('锟斤拷', '锟斤', '斤拷')
    foreach ($line in $lines) {
        $isMojibake = $false
        foreach ($char in $mojibakeChars) {
            if ($line.Contains($char)) {
                $isMojibake = $true
                break
            }
        }
        if (-not $isMojibake) {
            foreach ($compound in $mojibakeCompounds) {
                if ($line.Contains($compound)) {
                    $isMojibake = $true
                    break
                }
            }
        }
        if ($isMojibake) {
            # 跳过乱码行，不写入报告
            continue
        }
        [void]$safeLines.Add($line)
    }

    return ($safeLines -join "`r`n")
}
