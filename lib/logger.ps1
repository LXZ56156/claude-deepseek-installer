# ============================================================
# logger.ps1 - 日志和输出模块
# 提供统一的日志记录和彩色控制台输出功能
# ============================================================

# --- 编码初始化（延迟到 Initialize-ConsoleEncodingSafe，按 PS 版本/终端智能决策）---
# 不要在模块文件顶层无条件设置控制台编码。
# Windows PowerShell 5.1 + conhost + chcp 65001 可能导致中文叠字（如 [信信息息]）。
# 详见 Initialize-ConsoleEncodingSafe 的实现。

# 全局日志目录和文件路径
$script:LogDir = $null
$script:LogFile = $null

function Initialize-ConsoleEncodingSafe {
    <#
    .SYNOPSIS
        按 PowerShell 版本和终端类型智能初始化控制台编码。
        Windows PowerShell 5.1 Desktop + conhost 下不强制 chcp 65001，
        避免中文叠字（如 [信信息息]、正正在在检检测测）。
        日志文件始终用 UTF-8 写入，不受此函数影响。
    #>
    try {
        $isLegacyWindowsPowerShell = (
            $PSVersionTable.PSEdition -eq "Desktop" -and
            $PSVersionTable.PSVersion.Major -le 5
        )

        if ($isLegacyWindowsPowerShell) {
            Write-Log "DEBUG" "Legacy Windows PowerShell detected; skip forcing console UTF-8 to avoid duplicated Chinese glyphs."
            return
        }

        # PowerShell 7+ / Windows Terminal 场景：可以安全设置 UTF-8
        [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $script:OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        Write-Log "DEBUG" "Console UTF-8 initialized for non-legacy PowerShell."
    }
    catch {
        Write-Log "WARN" "Console encoding init skipped: $_"
    }
}

function Initialize-Logger {
    <#
    .SYNOPSIS
        初始化日志系统，创建日志目录和文件
    .PARAMETER LogDirPath
        日志目录路径，默认为脚本所在目录的 logs/ 子目录
    .PARAMETER ScriptName
        脚本名称（用于日志文件命名），默认自动检测调用者
    #>
    param(
        [string]$LogDirPath,
        [string]$ScriptName
    )

    if ($env:CCDI_TEST_MODE -eq "1" -and -not [string]::IsNullOrWhiteSpace($env:CCDI_TEST_ARTIFACT_ROOT)) {
        $LogDirPath = Join-Path $env:CCDI_TEST_ARTIFACT_ROOT "logs"
    }
    elseif (-not $LogDirPath) {
        $LogDirPath = Join-Path $PSScriptRoot "..\logs"
    }

    # 确保使用绝对路径
    $LogDirPath = [System.IO.Path]::GetFullPath($LogDirPath)

    $script:LogDir = $LogDirPath

    # 创建日志目录
    if (-not (Test-Path $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }

    # 生成日志文件名: 脚本名-时间戳.log
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

    # 优先使用传入的 ScriptName，其次从调用堆栈推断
    if (-not $ScriptName) {
        # 遍历调用堆栈找到第一个非 logger.ps1 的调用者
        $callStack = Get-PSCallStack
        foreach ($frame in $callStack) {
            if ($frame.ScriptName -and $frame.ScriptName -notmatch 'logger\.ps1$') {
                $ScriptName = [System.IO.Path]::GetFileNameWithoutExtension($frame.ScriptName)
                break
            }
        }
    }
    if (-not $ScriptName) {
        $ScriptName = "claude-installer"
    }

    $script:LogFile = Join-Path $script:LogDir "$ScriptName-$timestamp.log"

    # 按 PS 版本智能初始化控制台编码（Windows PS 5.1 不强制 UTF-8，避免中文叠字）
    Initialize-ConsoleEncodingSafe

    Write-Log "INFO" "========== 日志开始 =========="
    Write-Log "INFO" "日志文件: $script:LogFile"
}

function Write-Log {
    <#
    .SYNOPSIS
        写入一条日志记录到日志文件
    .PARAMETER Level
        日志级别：INFO, WARN, ERROR, DEBUG, OK, SKIP
    .PARAMETER Message
        日志消息内容
    #>
    param(
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG", "OK", "SKIP")]
        [string]$Level,
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"

    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $logLine -Encoding UTF8
    }
}

function Write-Info {
    <#
    .SYNOPSIS
        输出青色信息到控制台，并写入日志
    #>
    param([string]$Message)
    Write-Host "[信息] $Message" -ForegroundColor Cyan
    Write-Log "INFO" $Message
}

function Write-Success {
    <#
    .SYNOPSIS
        输出绿色成功信息到控制台，并写入日志
    #>
    param([string]$Message)
    Write-Host "[成功] $Message" -ForegroundColor Green
    Write-Log "INFO" "[OK] $Message"
}

function Write-Warning {
    <#
    .SYNOPSIS
        输出黄色警告信息到控制台，并写入日志
    #>
    param([string]$Message)
    Write-Host "[警告] $Message" -ForegroundColor Yellow
    Write-Log "WARN" $Message
}

function Write-Error-Msg {
    <#
    .SYNOPSIS
        输出红色错误信息到控制台，并写入日志
    #>
    param([string]$Message)
    Write-Host "[错误] $Message" -ForegroundColor Red
    Write-Log "ERROR" $Message
}

function Write-FatalError {
    <#
    .SYNOPSIS
        输出入口脚本顶层异常兜底信息。
    #>
    param(
        [string]$Message,
        [int]$ExitCode = 1
    )

    Write-Error-Msg $Message
    exit $ExitCode
}

function Write-Step {
    <#
    .SYNOPSIS
        输出当前执行步骤标题
    #>
    param([string]$StepName)
    $line = "=" * 60
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $StepName" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
    Write-Log "INFO" "--- 步骤: $StepName ---"
}

function Write-Result {
    <#
    .SYNOPSIS
        根据状态输出带图标的检测结果
    .PARAMETER Name
        检测项名称
    .PARAMETER Status
        状态：OK, WARN, ERROR, SKIP
    .PARAMETER Detail
        详细信息
    #>
    param(
        [string]$Name,
        [ValidateSet("OK", "WARN", "ERROR", "SKIP", "INFO")]
        [string]$Status,
        [string]$Detail = ""
    )

    $color = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "SKIP"  { "DarkGray" }
        "INFO"  { "Cyan" }
    }

    $output = "[$Status] $Name"
    if ($Detail) {
        $output += " - $Detail"
    }

    Write-Host $output -ForegroundColor $color
    # $Status 已经是字符串值 (OK/WARN/ERROR/SKIP)，直接作为日志级别使用
    Write-Log $Status $output
}

function Get-LogFilePath {
    <#
    .SYNOPSIS
        返回当前日志文件的完整路径
    #>
    return $script:LogFile
}

function Get-LogDir {
    <#
    .SYNOPSIS
        返回当前日志目录的完整路径
    #>
    return $script:LogDir
}

# ============================================================
# Terminal Transcript 函数 (v1.3.3)
# ============================================================

$script:TranscriptPath = $null
$script:TranscriptActive = $false

function Start-CcdiTranscriptSafe {
    <#
    .SYNOPSIS
        安全启动 PowerShell transcript，失败不阻断流程。
        记录用户实际看到的终端输出，供 support-feedback.txt 摘录使用。
    .PARAMETER Name
        Transcript 名称前缀（如 "start-here", "doctor"）
    .PARAMETER LogDir
        日志目录，默认使用已初始化的日志目录
    .RETURNS
        是否成功启动 transcript
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string]$LogDir = ""
    )

    if ($script:TranscriptActive) {
        Write-Log "DEBUG" "Start-CcdiTranscriptSafe: transcript 已激活，跳过"
        return $false
    }

    try {
        if (-not $LogDir) {
            $LogDir = $script:LogDir
        }
        if (-not $LogDir) {
            Write-Log "DEBUG" "Start-CcdiTranscriptSafe: 日志目录未初始化，跳过 transcript"
            return $false
        }

        if (-not (Test-Path $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }

        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $transcriptFile = Join-Path $LogDir "terminal-$Name-$timestamp.log"
        $script:TranscriptPath = $transcriptFile

        # try/catch 包裹，兼容 Windows PowerShell 5.1 的各种宿主
        try {
            Start-Transcript -Path $transcriptFile -Append -ErrorAction Stop | Out-Null
            $script:TranscriptActive = $true
            Write-Log "DEBUG" "Start-CcdiTranscriptSafe: transcript 已启动 -> $transcriptFile"
            return $true
        }
        catch {
            Write-Log "DEBUG" "Start-CcdiTranscriptSafe: Start-Transcript 失败（可能宿主不支持）: $_"
            $script:TranscriptPath = $null
            return $false
        }
    }
    catch {
        Write-Log "DEBUG" "Start-CcdiTranscriptSafe: 异常: $_"
        return $false
    }
}

function Stop-CcdiTranscriptSafe {
    <#
    .SYNOPSIS
        安全停止 PowerShell transcript，失败不阻断流程。
    #>
    if (-not $script:TranscriptActive) {
        return
    }

    try {
        try {
            Stop-Transcript -ErrorAction Stop | Out-Null
            Write-Log "DEBUG" "Stop-CcdiTranscriptSafe: transcript 已停止 -> $($script:TranscriptPath)"
        }
        catch {
            Write-Log "DEBUG" "Stop-CcdiTranscriptSafe: Stop-Transcript 失败: $_"
        }
    }
    catch {
        Write-Log "DEBUG" "Stop-CcdiTranscriptSafe: 异常: $_"
    }
    finally {
        $script:TranscriptActive = $false
        $script:TranscriptPath = $null
    }
}

function Get-LatestCcdiTranscript {
    <#
    .SYNOPSIS
        获取最近一次 terminal transcript 文件的路径。
    .PARAMETER LogDir
        日志目录，默认使用已初始化的日志目录
    .RETURNS
        最近 transcript 文件路径，不存在则返回 $null
    #>
    param([string]$LogDir = "")

    try {
        if (-not $LogDir) {
            $LogDir = $script:LogDir
        }
        if (-not $LogDir -or -not (Test-Path $LogDir)) {
            return $null
        }

        $terminalFiles = @(Get-ChildItem -Path $LogDir -Filter "terminal-*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        if ($terminalFiles.Count -gt 0) {
            return $terminalFiles[0].FullName
        }
        return $null
    }
    catch {
        return $null
    }
}
