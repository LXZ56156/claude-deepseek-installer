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
        IsTempPath = true → 普通 TEMP 目录，只 WARN
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

    if ($lower -match $temporaryInternetRegex -or $lower -match $compressedRegex) {
        $result.IsZipTemp = $true
        $result.Reason = "检测到压缩包或浏览器临时目录。请先完整解压 ZIP 到普通文件夹，例如 D:\\ClaudeDeepSeek。"
        return $result
    }

    # ============================================================
    # 第 2 遍：普通 TEMP 目录 → IsTempPath = true（WARN，不 BLOCK）
    # ============================================================
    if ($isUnderTemp) {
        $result.IsTempPath = $true
        $result.Reason = "当前路径在系统临时目录中，文件可能被自动清理导致数据丢失。建议移动到 D:\\ClaudeDeepSeek。"
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
        检测项目运行路径中存在的风险因素。
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

    # 先检测 ZIP 临时目录（这是 BLOCK 级别的）
    $zipCheck = Test-IsZipInternalPath -PathToCheck $PathToCheck
    if ($zipCheck.IsZipTemp) {
        $result.RiskLevel = "BLOCK"
        $result.IsBlocked = $true
        [void]$result.RiskItems.Add("ZIP临时目录: $($zipCheck.Reason)")
        [void]$result.Suggestions.Add("请先完整解压 ZIP 到普通文件夹，例如 D:\ClaudeDeepSeek，然后再双击开始安装.cmd。不要在压缩包预览窗口中直接运行。")
        return $result
    }

    # 普通 TEMP 目录：只 WARN，不 BLOCK
    if ($zipCheck.IsTempPath) {
        $result.RiskLevel = "WARN"
        [void]$result.RiskItems.Add("临时目录: $($zipCheck.Reason)")
        [void]$result.Suggestions.Add("建议将项目移动到 D:\ClaudeDeepSeek 等普通文件夹。")
    }

    $risks = [System.Collections.ArrayList]::new()

    # 空格检测
    if ($PathToCheck.Contains(" ")) {
        [void]$risks.Add("路径包含空格，可能影响某些脚本执行")
    }

    # 特殊字符检测
    if ($PathToCheck -match '[&^!()]') {
        [void]$risks.Add("路径包含特殊字符 (& ^ ! 括号)，可能导致命令行解析异常")
    }

    # OneDrive 检测
    if ($PathToCheck.ToLowerInvariant().Contains("onedrive")) {
        [void]$risks.Add("路径在 OneDrive 同步目录中，可能因同步冲突导致文件锁定或版本异常")
    }

    # Desktop/Downloads/微信/QQ 等常见接收目录
    $desktopLower = [Environment]::GetFolderPath("Desktop").ToLowerInvariant()
    if ($PathToCheck.ToLowerInvariant().StartsWith($desktopLower)) {
        [void]$risks.Add("路径在桌面目录中，桌面路径可能包含空格或特殊字符")
    }

    $userProfile = (Get-UserProfilePath).ToLowerInvariant()
    if ($PathToCheck.ToLowerInvariant().StartsWith("$userProfile\downloads")) {
        [void]$risks.Add("路径在下载目录中，部分安全软件可能拦截脚本运行")
    }

    if ($PathToCheck -match '(微信|WeChat|QQ|Tencent Files|钉钉|DingTalk)') {
        [void]$risks.Add("路径包含即时通讯软件接收目录，可能因文件锁定或权限问题导致运行失败")
    }

    # 路径长度检测
    $pathLen = $PathToCheck.Length
    if ($pathLen -gt 240) {
        [void]$risks.Add("路径过长 ($pathLen 字符，超过 240)，可能导致 Windows 路径长度限制问题")
    }
    elseif ($pathLen -gt 180) {
        [void]$risks.Add("路径较长 ($pathLen 字符)，建议使用更短的路径")
    }

    # UNC 路径检测
    if ($PathToCheck.StartsWith("\\")) {
        [void]$risks.Add("当前使用 UNC 网络路径，可能导致脚本执行权限问题。建议复制到本地磁盘。")
    }

    # WSL 路径（从 Windows 访问 WSL 文件系统）
    if ($PathToCheck.ToLowerInvariant().Contains("\\wsl.localhost") -or
        $PathToCheck.ToLowerInvariant().Contains("\\wsl$")) {
        [void]$risks.Add("当前在 WSL 文件系统路径中运行 Windows 脚本。请在 Windows 本地磁盘中解压运行，或在 WSL 内使用 install_wsl.sh。")
    }

    # 评估风险级别
    if ($risks.Count -gt 0) {
        $result.RiskLevel = "WARN"
        foreach ($r in $risks) { [void]$result.RiskItems.Add($r) }

        [void]$result.Suggestions.Add("建议将项目文件夹移动到 D:\ClaudeDeepSeek（或类似不含空格、特殊字符的路径），可以避免大多数路径相关问题。")
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
        [int]$TimeoutSec = 60,
        [string]$ProgressMessage = "",
        [int]$ProgressIntervalSec = 20
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

        Write-Log "DEBUG" "Invoke-CommandSafe: resolved=$startFile, cwd=$(Get-Location), args=$argumentLine, cmdPid=$($proc.Id)"

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
            Write-Log "ERROR" "命令超时 (${TimeoutSec}s): $Command $argumentLine"

            # 超时后先保存临时文件内容，再清理
            if (Test-Path $tmpOut) {
                try {
                    $partialOut = Get-Content $tmpOut -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if (-not [string]::IsNullOrWhiteSpace($partialOut)) {
                        $maxPartialLen = 4000
                        $result.Output = if ($partialOut.Length -gt $maxPartialLen) {
                            $partialOut.Substring(0, $maxPartialLen) + "`n...[截断]"
                        } else { $partialOut }
                        Write-Log "INFO" "超时部分 stdout ($($partialOut.Length) bytes): $(if ($partialOut.Length -gt 500) { $partialOut.Substring(0, 500) + '...' } else { $partialOut })"
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
                        Write-Log "INFO" "超时部分 stderr ($($partialErr.Length) bytes): $(if ($partialErr.Length -gt 500) { $partialErr.Substring(0, 500) + '...' } else { $partialErr })"
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
                if ($nonAscii -gt ($total * 0.6)) {
                    $hasValidCJK = $line -match '[\p{IsCJKUnifiedIdeographs}\p{IsCJKSymbolsAndPunctuation}\p{IsHiragana}\p{IsKatakana}]'
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

    # 2. 清除 ANSI escape 序列（防止报告中出现控制符）
    $result = Remove-AnsiEscape -Text $result

    # 3. 清除不可打印控制字符
    $result = Remove-ControlChars -Text $result

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
