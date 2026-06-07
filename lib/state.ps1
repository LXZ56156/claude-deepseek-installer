# ============================================================
# state.ps1 - 安装状态管理模块
# 管理 %USERPROFILE%\.claude-deepseek-installer\state.json
#
# 依赖: common.ps1, logger.ps1（需要先由调用方 dot-source）
# 注意: 本模块不自行 dot-source 依赖模块，由入口脚本统一管理加载顺序
# ============================================================

function Get-CcdiStateDir {
    <#
    .SYNOPSIS
        获取 CCDI 状态目录路径
    #>
    return Join-Path (Get-UserProfilePath) ".claude-deepseek-installer"
}

function Get-CcdiStateFile {
    <#
    .SYNOPSIS
        获取 CCDI 状态文件完整路径
    #>
    return Join-Path (Get-CcdiStateDir) "state.json"
}

function Read-CcdiState {
    <#
    .SYNOPSIS
        读取 CCDI 状态文件
    .RETURNS
        PSCustomObject 或 $null（文件不存在或损坏时）
    #>
    $stateFile = Get-CcdiStateFile

    if (-not (Test-Path $stateFile)) {
        Write-Log "DEBUG" "状态文件不存在: $stateFile"
        return $null
    }

    $state = Read-JsonFileSafe -FilePath $stateFile
    if ($null -eq $state) {
        Write-Log "WARN" "状态文件存在但无法解析: $stateFile"
        return $null
    }

    Write-Log "DEBUG" "已读取状态文件: $stateFile"
    return $state
}

function Write-CcdiState {
    <#
    .SYNOPSIS
        写入完整的 CCDI 状态文件（覆盖）
    .PARAMETER State
        要写入的状态对象（PSCustomObject 或 hashtable）
    .RETURNS
        是否写入成功
    #>
    param(
        [Parameter(Mandatory = $true)]
        $State
    )

    $stateDir = Get-CcdiStateDir
    $stateFile = Get-CcdiStateFile

    try {
        # 确保目录存在
        if (-not (Test-Path $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
            Write-Log "INFO" "创建 CCDI 状态目录: $stateDir"
        }

        $writeOk = Write-JsonFileSafe -FilePath $stateFile -Data $State
        if ($writeOk) {
            Write-Log "INFO" "状态文件已写入: $stateFile"
        }
        else {
            Write-Log "ERROR" "状态文件写入失败: $stateFile"
        }
        return $writeOk
    }
    catch {
        Write-Log "ERROR" "写入状态文件异常: $_"
        return $false
    }
}

function Update-CcdiState {
    <#
    .SYNOPSIS
        更新 CCDI 状态文件（读取 → 合并 → 写回）
    .PARAMETER Updates
        要合并更新的 hashtable
    .RETURNS
        合并后的状态对象
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Updates
    )

    $stateFile = Get-CcdiStateFile
    $existing = Read-CcdiState

    if ($null -eq $existing) {
        # 创建新状态
        $existing = [PSCustomObject]@{}
    }

    # 将现有状态转为 hashtable 便于合并
    $merged = @{}
    foreach ($prop in $existing.PSObject.Properties) {
        $merged[$prop.Name] = $prop.Value
    }

    # 用新值覆盖
    foreach ($key in $Updates.Keys) {
        $merged[$key] = $Updates[$key]
    }

    # 写回
    $writeOk = Write-CcdiState -State ([PSCustomObject]$merged)
    if ($writeOk) {
        Write-Log "DEBUG" "状态已更新"
    }

    return [PSCustomObject]$merged
}

function Initialize-CcdiState {
    <#
    .SYNOPSIS
        初始化 CCDI 状态（如果不存在），返回当前状态。
        每次运行入口脚本时调用，记录 lastRunAt。
    .PARAMETER ScriptVersion
        当前脚本版本号
    #>
    param(
        [string]$ScriptVersion = "1.3.1"
    )

    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $existing = Read-CcdiState

    if ($null -eq $existing) {
        $initialState = [PSCustomObject]@{
            scriptVersion            = $ScriptVersion
            installedAt              = $now
            lastRunAt                = $now
            claudeInstallMethod      = ""
            claudeWasAlreadyInstalled = $false
            claudeInstallStatus      = ""
            configPath               = ""
            lastBackupPath           = ""
            lastApiTest              = ""
        }
        Write-CcdiState -State $initialState | Out-Null
        Write-Log "INFO" "CCDI 状态文件已初始化"
        return $initialState
    }

    # 更新 lastRunAt
    return Update-CcdiState -Updates @{
        lastRunAt = $now
    }
}
