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

    $apiKeyCheck = Test-ApiKeyInputSafe -Key $ApiKey
    if (-not $apiKeyCheck.Valid) {
        $result.Error = "API Key 格式不安全: $($apiKeyCheck.Reason)"
        Write-Error-Msg $result.Error
        return $result
    }
    $ApiKey = $apiKeyCheck.Normalized

    Write-Log "INFO" "开始写入 DeepSeek 配置..."
    Write-Log "INFO" "目标配置文件: $ConfigPath"

    # 1. 在任何修改前创建内存快照（程序内部失败回滚源）
    $originalSnapshot = New-SettingsJsonMemorySnapshot -FilePath $ConfigPath
    if ($originalSnapshot.Error) {
        $result.Error = "读取原配置快照失败，已停止写入，避免破坏用户配置: $($originalSnapshot.Error)"
        Write-Error-Msg $result.Error
        return $result
    }

    # 2. 备份旧文件（脱敏安全备份，落盘售后参考）
    if (Test-Path -LiteralPath $ConfigPath) {
        $oldConfig = Read-JsonFileSafe -FilePath $ConfigPath
        if ($null -eq $oldConfig) {
            Write-Warning "检测到配置文件格式损坏，已生成脱敏备份，将重建配置。"
        }
        else {
            $oldProps = @(Get-JsonPropertyNamesSafe -Object $oldConfig)
            $hasDeepSeekEnv = $false
            if (($oldProps -contains "env") -and $null -ne $oldConfig.env -and
                ($oldConfig.env -is [System.Management.Automation.PSCustomObject])) {
                $oldEnvProps = @(Get-JsonPropertyNamesSafe -Object $oldConfig.env)
                if (($oldEnvProps -contains "ANTHROPIC_BASE_URL" -and [string]$oldConfig.env.ANTHROPIC_BASE_URL -match "api.deepseek.com") -or
                    ($oldEnvProps -contains "ANTHROPIC_AUTH_TOKEN" -and -not [string]::IsNullOrWhiteSpace([string]$oldConfig.env.ANTHROPIC_AUTH_TOKEN))) {
                    $hasDeepSeekEnv = $true
                }
            }

            if ($hasDeepSeekEnv) {
                Write-Info "检测到已有 DeepSeek 配置，将先生成脱敏安全备份，再更新。"
            }
            else {
                Write-Info "检测到 Claude Code 默认配置，正在安全合并 DeepSeek 设置。"
            }
        }

        $backupPath = Backup-SettingsJsonSafe -FilePath $ConfigPath
        $result.BackupPath = $backupPath

        # 备份失败则阻止继续写入
        if (-not $backupPath) {
            $result.Error = "已有配置文件安全备份失败，已停止写入，避免破坏用户配置。请检查 backup/ 目录权限或磁盘空间。"
            Write-Error-Msg $result.Error
            return $result
        }

        # 检查旧文件是否有效
        if ($null -eq $oldConfig) {
            $result.RebuiltFromDamagedJson = $true
            Write-Warning "旧配置文件 JSON 格式无效！已备份到: $backupPath"
            Write-Warning "将创建新的配置文件来替换。"
            Write-Warning "注意：由于旧 JSON 无法解析，permissions 等非 env 字段可能无法自动保留。"

            if (-not $NonInteractive -and -not (Confirm-UserChoice -Message "是否继续创建新配置？旧文件已备份" -Default "Yes")) {
                Write-Info "用户取消。旧文件已备份，未做任何修改。"
                $result.Error = "用户取消操作"
                return $result
            }

            if ($NonInteractive) {
                Write-Info "非交互模式：旧文件已备份，将继续创建新配置。"
            }
        }
    }
    else {
        Write-Info "正在创建 Claude Code 配置。"
    }

    # 3. 获取默认 env 配置
    try {
        $newEnv = Get-DefaultDeepSeekEnv -ApiKey $ApiKey
    }
    catch {
        $result.Error = $_.Exception.Message
        Write-Error-Msg "读取默认 DeepSeek 配置失败: $($result.Error)"
        return $result
    }

    # 4. 合并配置
    $merged = Merge-SettingsJson -ExistingPath $ConfigPath -NewEnv $newEnv

    if ($null -eq $merged) {
        $result.Error = "配置合并失败"
        Write-Error-Msg "配置合并失败，请检查日志。"
        return $result
    }

    # 5. 确保目录存在
    $configDir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        Write-Log "INFO" "创建配置目录: $configDir"
    }

    # 6. 写入配置
    $writeSuccess = Write-JsonFileSafe -FilePath $ConfigPath -Data $merged

    if (-not $writeSuccess) {
        $result.Error = "配置文件写入失败"
        Write-Error-Msg "写入配置文件失败，请检查磁盘空间和权限。"

        # 使用内存快照回滚，不能用脱敏备份（脱敏备份不含真实 Key）
        $rollback = Restore-SettingsJsonFromMemorySnapshot `
            -FilePath $ConfigPath `
            -Snapshot $originalSnapshot `
            -Reason "Write-DeepSeekConfig Write-JsonFileSafe failed"

        if (-not $rollback.Success) {
            Write-Warning "自动回滚失败：$($rollback.Error)"
        }
        return $result
    }

    # 7. 验证写入
    if (-not (Test-JsonValid -FilePath $ConfigPath)) {
        $result.Error = "写入的配置文件 JSON 格式无效"
        Write-Error-Msg "写入的配置文件格式验证失败！"

        # 使用内存快照回滚，不能用脱敏备份（脱敏备份不含真实 Key）
        $rollback = Restore-SettingsJsonFromMemorySnapshot `
            -FilePath $ConfigPath `
            -Snapshot $originalSnapshot `
            -Reason "Write-DeepSeekConfig post-write JSON validation failed"

        if (-not $rollback.Success) {
            Write-Warning "自动回滚失败：$($rollback.Error)"
        }
        return $result
    }

    Write-Success "DeepSeek 配置已成功写入！"
    Write-Log "INFO" "配置写入成功，备份: $($result.BackupPath)"

    # 如果是从损坏 JSON 重建，额外警告
    if ($result.RebuiltFromDamagedJson) {
        Write-Warning "本次配置是从损坏 JSON 重建的。旧配置中的非 env 字段（如 permissions）可能未保留。"
        Write-Warning "如需恢复，请从 backup/ 目录中的脱敏备份手动合并非敏感字段，并重新配置 API Key。"
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

function Get-JsonPropertyNamesSafe {
    param(
        [Parameter(Mandatory = $false)]
        $Object
    )

    if ($null -eq $Object) {
        return @()
    }

    if (-not ($Object -is [System.Management.Automation.PSCustomObject])) {
        return @()
    }

    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Test-JsonPropertyExists {
    param(
        [Parameter(Mandatory = $false)]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $names = @(Get-JsonPropertyNamesSafe -Object $Object)
    return ($names -contains $Name)
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

    $configNames = @(Get-JsonPropertyNamesSafe -Object $config)
    if (-not ($configNames -contains "env")) {
        $result.ErrorMessage = "配置文件中没有 env 字段"
        return $result
    }

    $env = $config.env

    # 防御: env 字段可能为 null
    if ($null -eq $env) {
        $result.ErrorMessage = "env 字段为空（null）"
        return $result
    }

    if (-not ($env -is [System.Management.Automation.PSCustomObject])) {
        $result.ErrorMessage = "env 字段类型异常"
        return $result
    }

    $envNames = @(Get-JsonPropertyNamesSafe -Object $env)
    if ($envNames.Count -eq 0) {
        $result.ErrorMessage = "env 字段为空对象，未配置 DeepSeek"
        return $result
    }

    # 检查 ANTHROPIC_BASE_URL
    $hasDeepSeekBaseUrl = $false
    if ($envNames -contains "ANTHROPIC_BASE_URL") {
        $result.BaseUrl = $env.ANTHROPIC_BASE_URL
        if ($result.BaseUrl -match "api.deepseek.com") {
            $hasDeepSeekBaseUrl = $true
        }
    }

    # 检查 ANTHROPIC_AUTH_TOKEN（排除空字符串情况）
    if ($envNames -contains "ANTHROPIC_AUTH_TOKEN" `
        -and -not [string]::IsNullOrEmpty($env.ANTHROPIC_AUTH_TOKEN)) {
        $tokenCheck = Test-ApiKeyInputSafe -Key ([string]$env.ANTHROPIC_AUTH_TOKEN)
        if ($tokenCheck.Valid) {
            $result.HasApiKey = $true
            $result.MaskedKey = Mask-ApiKey -Key $tokenCheck.Normalized
        }
        elseif ([string]$env.ANTHROPIC_AUTH_TOKEN -eq "__REDACTED_BY_CCDI__") {
            $result.MaskedKey = "(已脱敏，需要重新配置)"
            $result.ErrorMessage = "API Key 已脱敏，需要重新配置"
        }
    }

    $result.IsConfigured = ($hasDeepSeekBaseUrl -and $result.HasApiKey)
    if (-not $hasDeepSeekBaseUrl) {
        $result.ErrorMessage = "ANTHROPIC_BASE_URL 未指向 DeepSeek 官方接口"
    }
    elseif (-not $result.HasApiKey -and -not $result.ErrorMessage) {
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
    $configNames = @(Get-JsonPropertyNamesSafe -Object $config)
    if (-not ($configNames -contains "env")) { return $null }
    if ($null -eq $config.env) { return $null }
    if (-not ($config.env -is [System.Management.Automation.PSCustomObject])) { return $null }

    $envNames = @(Get-JsonPropertyNamesSafe -Object $config.env)
    if (-not ($envNames -contains "ANTHROPIC_AUTH_TOKEN")) { return $null }

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

    function _RestoreSingleBackup {
        param(
            [string]$SourcePath,
            [string]$SourceName
        )

        # 在复制备份之前创建当前配置的内存快照（用于失败回滚）
        $preRestoreSnapshot = New-SettingsJsonMemorySnapshot -FilePath $configPath
        if ($preRestoreSnapshot.Error) {
            $result.Message = "读取当前配置快照失败，已停止恢复，避免破坏用户配置: $($preRestoreSnapshot.Error)"
            Write-Error-Msg $result.Message
            return $false
        }

        # 确保配置目录存在
        $configDir = Split-Path -Parent $configPath
        if ($configDir -and -not (Test-Path -LiteralPath $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }

        Copy-Item -LiteralPath $SourcePath -Destination $configPath -Force
        if (-not (Test-JsonValid -FilePath $configPath)) {
            Write-Error-Msg "恢复后 JSON 校验失败，正在回滚。"

            # 使用内存快照回滚，不能用脱敏备份（脱敏备份不含真实 Key）
            $rollback = Restore-SettingsJsonFromMemorySnapshot `
                -FilePath $configPath `
                -Snapshot $preRestoreSnapshot `
                -Reason "Restore-ConfigFromBackup post-restore JSON validation failed ($SourceName)"

            if ($rollback.Success) {
                Write-Warning "恢复失败，已回滚到恢复前配置。"
            }
            else {
                Write-Warning "恢复失败，且自动回滚失败：$($rollback.Error)"
            }
            return $false
        }

        $result.Success = $true
        $result.Message = "已从备份恢复: $SourceName"
        Write-Success $result.Message
        $restoredStatus = Get-DeepSeekConfigStatus
        if ($restoredStatus.ErrorMessage -match "脱敏") {
            Write-Warning "已恢复非敏感配置，但 API Key 已脱敏，需要重新配置。"
        }
        return $true
    }

    if ($BackupPath -and (Test-Path $BackupPath)) {
        # 使用指定的备份文件
        if ([System.IO.Path]::GetFileName($BackupPath) -match '\.invalid') {
            $result.Message = "该备份是损坏配置的脱敏文本备份，不能恢复为 settings.json"
            Write-Error-Msg $result.Message
            return $result
        }
        $backupJson = Read-JsonFileSafe -FilePath $BackupPath
        if ($null -eq $backupJson) {
            $result.Message = "该备份已损坏，未恢复"
            Write-Error-Msg $result.Message
            return $result
        }
        [void](_RestoreSingleBackup -SourcePath $BackupPath -SourceName $BackupPath)
        return $result
    }

    # 列出可用备份
    $backups = @(Get-ChildItem -Path $fullBackupDir -Filter "settings.json.*.bak" | Sort-Object Name -Descending)

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
            if ($selected.Name -match '\.invalid') {
                $result.Message = "该备份已损坏，未恢复"
                Write-Error-Msg $result.Message
                return $result
            }
            $selectedJson = Read-JsonFileSafe -FilePath $selected.FullName
            if ($null -eq $selectedJson) {
                $result.Message = "该备份已损坏，未恢复"
                Write-Error-Msg $result.Message
                return $result
            }
            [void](_RestoreSingleBackup -SourcePath $selected.FullName -SourceName $selected.Name)
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
