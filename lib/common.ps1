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
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
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

# ============================================================
# JSON 处理函数
# ============================================================

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
    if (($existing.PSObject.Properties.Name -contains "env") -and $null -ne $existing.env) {
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
        弹出确认提示，要求用户输入 Y/N
    .PARAMETER Message
        提示消息
    .RETURNS
        用户选择 Yes 返回 $true
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $response = Read-Host "$Message (Y/N)"
    return ($response -eq "Y" -or $response -eq "y" -or $response -eq "是")
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
# PATH 刷新
# ============================================================

function Refresh-CurrentProcessPath {
    <#
    .SYNOPSIS
        将 Machine 和 User 级别的 PATH 环境变量合并到当前进程。
        用于 Native Install / npm / winget 安装后刷新 PATH。
    #>
    try {
        $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $combined = @()
        if ($userPath) { $combined += $userPath }
        if ($machinePath) { $combined += $machinePath }
        $env:Path = ($combined -join ";") + ";" + $env:Path
        Write-Log "INFO" "PATH 已刷新（合并 Machine + User 到当前进程）"
    }
    catch {
        Write-Log "WARN" "PATH 刷新失败: $_"
    }
}

# ============================================================
# 命令检测函数
# ============================================================

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
    .RETURNS
        包含 Success, ExitCode, Output, Error 的哈希表
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 60
    )

    $result = @{
        Success  = $false
        ExitCode = -1
        Output   = ""
        Error    = ""
    }

    $tmpOut = $null
    $tmpErr = $null

    try {
        # 使用唯一临时文件名避免并发冲突
        $tempDir = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
        $tmpOut = Join-Path $tempDir "ccdi_stdout_${PID}_$(Get-Random).tmp"
        $tmpErr = Join-Path $tempDir "ccdi_stderr_${PID}_$(Get-Random).tmp"

        $argumentLine = ConvertTo-CommandLine -Arguments $Arguments

        $proc = Start-Process -FilePath $Command -ArgumentList $argumentLine `
            -NoNewWindow -PassThru -RedirectStandardOutput $tmpOut `
            -RedirectStandardError $tmpErr

        # 等待进程完成，设置超时
        $finished = $proc.WaitForExit($TimeoutSec * 1000)

        if (-not $finished) {
            # 超时：强制终止进程
            $proc.Kill()
            $proc.WaitForExit(5000) | Out-Null
            $result.Error = "命令执行超时 (${TimeoutSec}秒): $Command"
            $result.Success = $false
            Write-Log "ERROR" "命令超时: $Command $argumentLine"
            return $result
        }

        $result.ExitCode = $proc.ExitCode
        $result.Success = ($proc.ExitCode -eq 0)

        if ($tmpOut -and (Test-Path $tmpOut)) {
            $result.Output = Get-Content $tmpOut -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        if ($tmpErr -and (Test-Path $tmpErr)) {
            $result.Error = Get-Content $tmpErr -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    }
    catch {
        $result.Error = $_.Exception.Message
        Write-Log "ERROR" "命令执行异常: $Command $Arguments, 错误: $($_.Exception.Message)"
    }
    finally {
        if ($tmpOut -and (Test-Path $tmpOut)) {
            Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue
        }
        if ($tmpErr -and (Test-Path $tmpErr)) {
            Remove-Item $tmpErr -Force -ErrorAction SilentlyContinue
        }
    }

    return $result
}

function ConvertTo-CommandLine {
    <#
    .SYNOPSIS
        将参数数组转换为兼容 Windows PowerShell 5.1 Start-Process 的命令行。
    #>
    param([string[]]$Arguments = @())

    if (-not $Arguments -or $Arguments.Count -eq 0) {
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
    if (($clone.PSObject.Properties.Name -contains "env") -and $null -ne $clone.env) {
        if ($clone.env.PSObject.Properties.Name -contains "ANTHROPIC_AUTH_TOKEN") {
            $clone.env.ANTHROPIC_AUTH_TOKEN = Mask-ApiKey -Key $clone.env.ANTHROPIC_AUTH_TOKEN
        }
    }

    return ($clone | ConvertTo-Json -Depth 10)
}
