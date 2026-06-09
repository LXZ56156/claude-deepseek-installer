# ============================================================
# config-writer.ps1 - 配置写入模块
# 负责 DeepSeek API 配置的读取、合并、写入和验证
#
# 依赖: common.ps1, logger.ps1（需要先由调用方 dot-source）
# 注意: 本模块不自行 dot-source 依赖模块，由入口脚本统一管理加载顺序
# ============================================================

# ============================================================
# DeepSeek 默认配置
# ============================================================

function Get-DefaultDeepSeekEnv {
    <#
    .SYNOPSIS
        返回 DeepSeek Claude-compatible 默认环境变量配置
    .PARAMETER ApiKey
        DeepSeek API Key（不含前缀 Bearer，由 Claude Code 自动处理）
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiKey
    )

    $template = Get-DefaultDeepSeekEnvTemplate
    $env = @{}

    foreach ($prop in $template.PSObject.Properties) {
        if ($prop.Name -eq "ANTHROPIC_AUTH_TOKEN") {
            $env[$prop.Name] = $ApiKey
        }
        else {
            $env[$prop.Name] = $prop.Value
        }
    }

    return $env
}

function Get-DefaultDeepSeekEnvTemplate {
    <#
    .SYNOPSIS
        从共享 JSON 模板读取 DeepSeek 默认环境变量。
    #>
    $defaultsPath = Get-DeepSeekDefaultsPath
    $template = Read-JsonFileSafe -FilePath $defaultsPath

    if ($null -eq $template) {
        throw "无法读取默认 DeepSeek 配置模板: $defaultsPath"
    }

    return $template
}

function Get-DeepSeekDefaultsPath {
    if (Get-Variable -Name CcdiProjectRoot -Scope Script -ErrorAction SilentlyContinue) {
        return Join-Path $script:CcdiProjectRoot "lib\deepseek-env.defaults.json"
    }

    return Join-Path $PSScriptRoot "deepseek-env.defaults.json"
}

# ============================================================
# 配置写入
# ============================================================

function Write-DeepSeekConfig {
    <#
    .SYNOPSIS
        写入 DeepSeek 配置到 Claude Code settings.json
        自动备份旧文件（如果存在），合并 env 字段
    .PARAMETER ApiKey
        DeepSeek API Key
    .PARAMETER ConfigPath
        settings.json 路径，默认使用 %USERPROFILE%\.claude\settings.json
    .RETURNS
        包含 Success, BackupPath, ConfigPath, Error 的哈希表
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiKey,
        [string]$ConfigPath = $null,
        [switch]$NonInteractive
    )

    $result = @{
        Success    = $false
        BackupPath = $null
        ConfigPath = $null
        Error      = ""
        RebuiltFromDamagedJson = $false
    }

    if (-not $ConfigPath) {
        $ConfigPath = Get-ClaudeConfigFile
    }
    $result.ConfigPath = $ConfigPath

    Write-Log "INFO" "开始写入 DeepSeek 配置..."
    Write-Log "INFO" "目标配置文件: $ConfigPath"

    # 1. 备份旧文件
    if (Test-Path $ConfigPath) {
        Write-Info "检测到已有配置文件，正在备份..."
        $backupPath = Backup-File -FilePath $ConfigPath
        $result.BackupPath = $backupPath

        # 备份失败则阻止继续写入
        if (-not $backupPath) {
            $result.Error = "已有配置文件备份失败，已停止写入，避免破坏用户配置。请检查 backup/ 目录权限或磁盘空间。"
            Write-Error-Msg $result.Error
            return $result
        }

        # 检查旧文件是否有效
        if (-not (Test-JsonValid -FilePath $ConfigPath)) {
            $result.RebuiltFromDamagedJson = $true
            Write-Warning "旧配置文件 JSON 格式无效！已备份到: $backupPath"
            Write-Warning "将创建新的配置文件来替换。"
            Write-Warning "注意：由于旧 JSON 无法解析，permissions 等非 env 字段可能无法自动保留。"

            if (-not $NonInteractive -and -not (Confirm-UserChoice -Message "是否继续创建新配置？旧文件已备份")) {
                Write-Info "用户取消。旧文件已备份，未做任何修改。"
                $result.Error = "用户取消操作"
                return $result
            }

            if ($NonInteractive) {
                Write-Info "非交互模式：旧文件已备份，将继续创建新配置。"
            }
        }
    }

    # 2. 获取默认 env 配置
    try {
        $newEnv = Get-DefaultDeepSeekEnv -ApiKey $ApiKey
    }
    catch {
        $result.Error = $_.Exception.Message
        Write-Error-Msg "读取默认 DeepSeek 配置失败: $($result.Error)"
        return $result
    }

    # 3. 合并配置
    $merged = Merge-SettingsJson -ExistingPath $ConfigPath -NewEnv $newEnv

    if ($null -eq $merged) {
        $result.Error = "配置合并失败"
        Write-Error-Msg "配置合并失败，请检查日志。"
        return $result
    }

    # 4. 确保目录存在
    $configDir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        Write-Log "INFO" "创建配置目录: $configDir"
    }

    # 5. 写入配置
    $writeSuccess = Write-JsonFileSafe -FilePath $ConfigPath -Data $merged

    if (-not $writeSuccess) {
        $result.Error = "配置文件写入失败"
        Write-Error-Msg "写入配置文件失败，请检查磁盘空间和权限。"
        return $result
    }

    # 6. 验证写入
    if (-not (Test-JsonValid -FilePath $ConfigPath)) {
        $result.Error = "写入的配置文件 JSON 格式无效"
        Write-Error-Msg "写入的配置文件格式验证失败！"

        # 如果有备份，尝试恢复
        if ($result.BackupPath) {
            Write-Warning "正在恢复备份文件..."
            Copy-Item -Path $result.BackupPath -Destination $ConfigPath -Force
            Write-Info "已恢复备份文件。"
        }
        return $result
    }

    Write-Success "DeepSeek 配置已成功写入！"
    Write-Log "INFO" "配置写入成功，备份: $($result.BackupPath)"

    # 如果是从损坏 JSON 重建，额外警告
    if ($result.RebuiltFromDamagedJson) {
        Write-Warning "本次配置是从损坏 JSON 重建的。旧配置中的非 env 字段（如 permissions）可能未保留。"
        Write-Warning "如需恢复，请从 backup/ 目录手动合并。"
    }

    # 输出脱敏后的配置摘要
    $maskedKey = Mask-ApiKey -Key $ApiKey
    Write-Info "API Key 已保存: $maskedKey"
    Write-Info "配置文件位置: $ConfigPath"

    $result.Success = $true
    return $result
}

# ============================================================
# 配置读取和验证
# ============================================================

function Read-ClaudeConfig {
    <#
    .SYNOPSIS
        读取 Claude Code 配置
    .RETURNS
        PSCustomObject 或 $null
    #>
    param([string]$ConfigPath = $null)

    $configPath = if ($ConfigPath) { $ConfigPath } else { Get-ClaudeConfigFile }
    return Read-JsonFileSafe -FilePath $configPath
}

function Get-DeepSeekConfigStatus {
    <#
    .SYNOPSIS
        检查 DeepSeek 配置状态
    .RETURNS
        包含 IsConfigured, BaseUrl, HasApiKey, MaskedKey, Fields 的哈希表
    #>
    $config = Read-ClaudeConfig
    $result = @{
        IsConfigured = $false
        BaseUrl      = $null
        HasApiKey    = $false
        MaskedKey    = "(未设置)"
        ErrorMessage = $null
    }

    if ($null -eq $config) {
        $result.ErrorMessage = "配置文件不存在或格式无效"
        return $result
    }

    if (-not ($config.PSObject.Properties.Name -contains "env")) {
        $result.ErrorMessage = "配置文件中没有 env 字段"
        return $result
    }

    $env = $config.env

    # 防御: env 字段可能为 null
    if ($null -eq $env) {
        $result.ErrorMessage = "env 字段为空（null）"
        return $result
    }

    # 检查 ANTHROPIC_BASE_URL
    $hasDeepSeekBaseUrl = $false
    if ($env.PSObject.Properties.Name -contains "ANTHROPIC_BASE_URL") {
        $result.BaseUrl = $env.ANTHROPIC_BASE_URL
        if ($result.BaseUrl -match "api.deepseek.com") {
            $hasDeepSeekBaseUrl = $true
        }
    }

    # 检查 ANTHROPIC_AUTH_TOKEN（排除空字符串情况）
    if ($env.PSObject.Properties.Name -contains "ANTHROPIC_AUTH_TOKEN" `
        -and -not [string]::IsNullOrEmpty($env.ANTHROPIC_AUTH_TOKEN)) {
        $result.HasApiKey = $true
        $result.MaskedKey = Mask-ApiKey -Key $env.ANTHROPIC_AUTH_TOKEN
    }

    $result.IsConfigured = ($hasDeepSeekBaseUrl -and $result.HasApiKey)
    if (-not $hasDeepSeekBaseUrl) {
        $result.ErrorMessage = "ANTHROPIC_BASE_URL 未指向 DeepSeek 官方接口"
    }
    elseif (-not $result.HasApiKey) {
        $result.ErrorMessage = "未设置 API Key"
    }

    return $result
}

function Get-ApiKeyFromConfig {
    <#
    .SYNOPSIS
        从配置文件中读取 API Key
        注意：此函数只应在需要实际使用 Key 时调用，不应将 Key 写入日志
    .RETURNS
        API Key 字符串或 $null
    #>
    $config = Read-ClaudeConfig
    if ($null -eq $config) { return $null }
    if (-not ($config.PSObject.Properties.Name -contains "env")) { return $null }
    if ($null -eq $config.env) { return $null }
    if (-not ($config.env.PSObject.Properties.Name -contains "ANTHROPIC_AUTH_TOKEN")) { return $null }

    return $config.env.ANTHROPIC_AUTH_TOKEN
}

# ============================================================
# 配置恢复
# ============================================================

function Restore-ConfigFromBackup {
    <#
    .SYNOPSIS
        从备份恢复配置文件
    .PARAMETER BackupPath
        备份文件路径。如果未指定，列出可用备份让用户选择。
    .RETURNS
        包含 Success, Message 的哈希表
    #>
    param(
        [string]$BackupPath = $null
    )

    $result = @{
        Success = $false
        Message = ""
    }

    $backupDir = Get-BackupDir
    $fullBackupDir = [System.IO.Path]::GetFullPath($backupDir)
    $configPath = Get-ClaudeConfigFile

    if (-not (Test-Path $fullBackupDir)) {
        $result.Message = "备份目录不存在，没有可恢复的备份"
        Write-Error-Msg $result.Message
        return $result
    }

    if ($BackupPath -and (Test-Path $BackupPath)) {
        # 使用指定的备份文件
        Copy-Item -Path $BackupPath -Destination $configPath -Force
        $result.Success = $true
        $result.Message = "已从 $BackupPath 恢复配置"
        Write-Success $result.Message
        return $result
    }

    # 列出可用备份
    $backups = Get-ChildItem -Path $fullBackupDir -Filter "settings.json.*.bak" | Sort-Object Name -Descending

    if ($backups.Count -eq 0) {
        $result.Message = "备份目录中没有找到 settings.json 的备份文件"
        Write-Warning $result.Message
        return $result
    }

    Write-Info "找到以下备份文件:"
    for ($i = 0; $i -lt $backups.Count; $i++) {
        $index = $i + 1
        $name = $backups[$i].Name
        $time = $backups[$i].LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        Write-Host "  [$index] $name ($time)" -ForegroundColor Cyan
    }

    $choice = Read-Host "请输入要恢复的备份编号 (1-$($backups.Count)，输入 0 取消)"
    try {
        $choiceNum = [int]$choice
        if ($choiceNum -eq 0) {
            $result.Message = "用户取消恢复操作"
            return $result
        }
        if ($choiceNum -ge 1 -and $choiceNum -le $backups.Count) {
            $selected = $backups[$choiceNum - 1]
            Copy-Item -Path $selected.FullName -Destination $configPath -Force
            $result.Success = $true
            $result.Message = "已从备份恢复: $($selected.Name)"
            Write-Success $result.Message
        }
        else {
            $result.Message = "无效的选择"
            Write-Error-Msg $result.Message
        }
    }
    catch {
        $result.Message = "输入无效: $_"
        Write-Error-Msg $result.Message
    }

    return $result
}
