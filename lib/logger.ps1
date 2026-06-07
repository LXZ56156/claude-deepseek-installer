# ============================================================
# logger.ps1 - 日志和输出模块
# 提供统一的日志记录和彩色控制台输出功能
# ============================================================

# 全局日志目录和文件路径
$script:LogDir = $null
$script:LogFile = $null

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

    if (-not $LogDirPath) {
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
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [object]$ErrorRecord = $null
    )

    Write-Error-Msg $Message
    if ($ErrorRecord) {
        Write-Log "ERROR" $ErrorRecord
    }

    if (Get-Command Get-LogFilePath -ErrorAction SilentlyContinue) {
        $logFile = Get-LogFilePath
        if ($logFile) {
            Write-Info "日志文件: $logFile"
        }
    }

    Write-Info "如问题持续，请运行「一键诊断.cmd」并将 report.txt 发给技术支持。"
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
        [ValidateSet("OK", "WARN", "ERROR", "SKIP")]
        [string]$Status,
        [string]$Detail = ""
    )

    $icon = switch ($Status) {
        "OK"    { "" }
        "WARN"  { "️ " }
        "ERROR" { "" }
        "SKIP"  { "⏭️ " }
    }

    $color = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "SKIP"  { "DarkGray" }
    }

    $output = "[$icon] $Name"
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
