# ============================================================
# uninstall-config.ps1 - 配置恢复/卸载脚本
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File .\uninstall-config.ps1
#   powershell -ExecutionPolicy Bypass -File .\uninstall-config.ps1 -RemoveDeepSeekEnv -Yes
#   powershell -ExecutionPolicy Bypass -File .\uninstall-config.ps1 -RestoreLatest -Yes
#   powershell -ExecutionPolicy Bypass -File .\uninstall-config.ps1 -DeleteSettings -Yes
#   powershell -ExecutionPolicy Bypass -File .\uninstall-config.ps1 -ListBackups
#   powershell -ExecutionPolicy Bypass -File .\uninstall-config.ps1 -ShowStatusOnly
#
# 功能:
#   恢复旧配置备份，或清空 DeepSeek API 配置
#   不会删除 Claude Code 本身
# ============================================================

param(
    [switch]$RemoveDeepSeekEnv,
    [switch]$RestoreLatest,
    [switch]$DeleteSettings,
    [switch]$ListBackups,
    [switch]$ShowStatusOnly,
    [switch]$Yes,
    [switch]$NonInteractive
)

try {

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$EntryScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $EntryScriptDir) { $EntryScriptDir = (Get-Location).Path }
. (Join-Path $EntryScriptDir "lib\bootstrap.ps1")
$ScriptDir = Initialize-CcdiScript -ScriptName "uninstall-config"

function Get-ManagedDeepSeekFields {
    return @(
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "CLAUDE_CODE_SUBAGENT_MODEL",
        "CLAUDE_CODE_EFFORT_LEVEL",
        "API_TIMEOUT_MS",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
        "DISABLE_TELEMETRY",
        "DISABLE_ERROR_REPORTING",
        "DISABLE_AUTOUPDATER"
    )
}

function Get-ConfigBackups {
    $backupDir = Get-BackupDir
    if (-not (Test-Path $backupDir)) {
        return @()
    }

    return @(Get-ChildItem -Path $backupDir -Filter "settings.json.*.bak" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending)
}

function Show-ConfigBackups {
    $backups = @(Get-ConfigBackups)
    if ($backups.Count -eq 0) {
        Write-Warning "没有找到可恢复的 settings.json 备份。"
        return
    }

    Write-Info "找到 $($backups.Count) 个 settings.json 备份:"
    Write-Host ""

    for ($i = 0; $i -lt $backups.Count; $i++) {
        $backup = $backups[$i]
        Write-Host ("  [{0}] {1}" -f ($i + 1), $backup.Name) -ForegroundColor White
        Write-Host ("      时间: {0}" -f $backup.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")) -ForegroundColor Gray
        Write-Host ("      路径: {0}" -f $backup.FullName) -ForegroundColor Gray
    }
}

function Remove-DeepSeekEnvConfig {
    param([switch]$AssumeYes)

    $managedFields = Get-ManagedDeepSeekFields
    $configPath = Get-ClaudeConfigFile

    if (-not (Test-Path $configPath)) {
        Write-Info "配置文件不存在，无需操作。"
        return $true
    }

    if (-not $AssumeYes) {
        Write-Warning "即将移除 DeepSeek 相关 env 字段，但保留其他配置。"
        Write-Info "将移除字段: $($managedFields -join ', ')"
        if (-not (Confirm-UserChoice -Message "确认移除？")) {
            Write-Info "已取消。"
            return $false
        }
    }

    $backupResult = Backup-File -FilePath $configPath
    if (-not $backupResult) {
        Write-Error-Msg "配置文件备份失败，已停止修改，避免破坏用户配置。"
        return $false
    }

    $config = Read-JsonFileSafe -FilePath $configPath
    if (-not $config) {
        Write-Error-Msg "配置文件 JSON 无法解析。已备份，但不会尝试修改。"
        return $false
    }

    $envHash = @{}
    $removedCount = 0

    $configProps = @(Get-JsonPropertyNamesSafe -Object $config)
    if (($configProps -contains "env") -and $null -ne $config.env) {
        if ($config.env -is [System.Management.Automation.PSCustomObject]) {
            foreach ($prop in $config.env.PSObject.Properties) {
                if ($prop.Name -in $managedFields) {
                    $removedCount++
                }
                else {
                    $envHash[$prop.Name] = $prop.Value
                }
            }
        }
        else {
            Write-Warning "env 字段类型异常，将重建为空对象。原始配置已备份。"
        }
    }

    $newConfig = [PSCustomObject]@{}
    foreach ($prop in $config.PSObject.Properties) {
        if ($prop.Name -ne "env") {
            Add-Member -InputObject $newConfig -MemberType NoteProperty -Name $prop.Name -Value $prop.Value
        }
    }
    Add-Member -InputObject $newConfig -MemberType NoteProperty -Name "env" -Value ([PSCustomObject]$envHash)

    if (-not (Write-JsonFileSafe -FilePath $configPath -Data $newConfig)) {
        Write-Error-Msg "配置写回失败，备份已保留。"
        return $false
    }

    Write-Success "已移除 $removedCount 个 DeepSeek 相关 env 字段。"
    Write-Info "其他 env 和配置项已保留。"
    return $true
}

function Restore-LatestConfigBackup {
    param([switch]$AssumeYes)

    $latest = @(Get-ConfigBackups) | Select-Object -First 1
    if (-not $latest) {
        Write-Warning "没有找到可恢复的 settings.json 备份。"
        return $false
    }

    if (-not $AssumeYes) {
        Write-Warning "即将恢复最新备份: $($latest.FullName)"
        if (-not (Confirm-UserChoice -Message "确认恢复？")) {
            Write-Info "已取消。"
            return $false
        }
    }

    $configPath = Get-ClaudeConfigFile
    if (Test-Path $configPath) {
        $preBackup = Backup-File -FilePath $configPath
        if (-not $preBackup) {
            Write-Error-Msg "恢复前备份当前配置失败，已停止。"
            return $false
        }
    }

    $configDir = Split-Path -Parent $configPath
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    Copy-Item -Path $latest.FullName -Destination $configPath -Force
    Write-Success "已恢复最新备份: $($latest.Name)"
    return $true
}

function Remove-SettingsFile {
    param([switch]$AssumeYes)

    $configPath = Get-ClaudeConfigFile
    if (-not (Test-Path $configPath)) {
        Write-Info "配置文件不存在，无需操作。"
        return $true
    }

    if (-not $AssumeYes) {
        Write-Warning "即将删除整个配置文件: $configPath"
        Write-Warning "这将移除所有 Claude Code 配置（不仅是 DeepSeek 相关）。"
        if (-not (Confirm-UserChoice -Message "确认删除整个配置文件？此操作不可恢复！")) {
            Write-Info "已取消。"
            return $false
        }
    }

    $backupResult = Backup-File -FilePath $configPath
    if (-not $backupResult) {
        Write-Error-Msg "配置文件备份失败，已停止删除操作。"
        return $false
    }

    Remove-Item -Path $configPath -Force
    Write-Success "配置文件已删除。备份保留在 backup/ 目录。"
    return $true
}

function Show-StateAndCurrentConfig {
    $state = Read-CcdiState

    if ($state) {
        $installMethod = Get-CcdiStateValue -State $state -Name "claudeInstallMethod" -Default "(未知)"
        $installStatus = Get-CcdiStateValue -State $state -Name "claudeInstallStatus" -Default "(未知)"
        $installedAt = Get-CcdiStateValue -State $state -Name "installedAt" -Default "(未记录)"
        $wasAlreadyInstalled = Get-CcdiStateValue -State $state -Name "claudeWasAlreadyInstalled" -Default $null

        $wasAlreadyInstalledText = if ($wasAlreadyInstalled -eq $true) {
            "是"
        }
        elseif ($wasAlreadyInstalled -eq $false) {
            "否"
        }
        else {
            "(未记录)"
        }

        Write-Info "本工具记录的安装信息:"
        Write-Info "  安装方式: $installMethod"
        Write-Info "  Claude Code 原本已安装: $wasAlreadyInstalledText"
        Write-Info "  安装状态: $installStatus"
        Write-Info "  安装时间: $installedAt"
        Write-Host ""
    }

    Write-Info "此工具可以帮助您:"
    Write-Info "  1. 从备份恢复之前的配置文件"
    Write-Info "  2. 移除本工具写入的 DeepSeek 配置（保留您自己的其他 env 和配置）"
    Write-Info "  3. 删除整个配置文件"
    Write-Info ""

    if ($state) {
        if ($wasAlreadyInstalled -eq $true) {
            Write-Warning "Claude Code 原本已存在（非本工具安装），不建议卸载 Claude Code。"
            Write-Info "本工具仅管理 DeepSeek 配置的恢复/清理。"
        }
        elseif ($installMethod -eq "npm" -or $installMethod -eq "npm_npmmirror") {
            Write-Info "Claude Code 通过 npm 安装。如需卸载，可运行: npm uninstall -g @anthropic-ai/claude-code"
        }
        elseif ($installMethod -eq "native" -or $installMethod -eq "official_native") {
            Write-Info "Claude Code 通过官方 Native Install 安装。本工具暂不自动卸载。"
            Write-Info "卸载请参考 Claude Code 官方文档。本工具仅管理配置。"
        }
        elseif ($installMethod -eq "node-via-winget") {
            Write-Info "Node.js 通过 winget 安装（Claude Code 尚未完成安装）。"
        }
        elseif ($installMethod -eq "existing") {
            Write-Info "Claude Code 是运行前已存在的安装。本工具仅管理 DeepSeek 配置。"
        }
    }
    else {
        Write-Warning "未找到安装状态记录，无法确认 Claude Code 是否由本工具安装。"
        Write-Warning "为避免误删，仅提供配置恢复/清理功能。"
    }
    Write-Host ""

    $currentConfig = Get-DeepSeekConfigStatus
    Write-Info "当前配置状态:"
    Write-Info "  Base URL: $(if ($currentConfig.BaseUrl) { $currentConfig.BaseUrl } else { '(未设置)' })"
    Write-Info "  API Key:  $($currentConfig.MaskedKey)"
    Write-Host ""
}

function Show-InteractiveMenu {
    Write-Host "请选择操作:" -ForegroundColor Cyan
    Write-Host "  [1] 从备份恢复配置" -ForegroundColor White
    Write-Host "  [2] 仅移除本工具写入的 DeepSeek env（保留其他 env 和配置）" -ForegroundColor White
    Write-Host "  [3] 删除整个配置文件" -ForegroundColor White
    Write-Host "  [4] 退出" -ForegroundColor White
    Write-Host ""

    $choice = Read-Host "请输入选项 (1-4)"

    switch ($choice) {
        "1" { [void](Restore-LatestConfigBackup) }
        "2" { [void](Remove-DeepSeekEnvConfig) }
        "3" { [void](Remove-SettingsFile) }
        "4" { Write-Info "已退出。" }
        default { Write-Error-Msg "无效选项。" }
    }
}

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "           配置恢复/卸载工具                                  " -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""

if ($ListBackups) {
    Show-ConfigBackups
    exit 0
}

Show-StateAndCurrentConfig

if ($ShowStatusOnly) {
    exit 0
}

$assumeYes = $Yes -or $NonInteractive

if ($RemoveDeepSeekEnv) {
    $ok = Remove-DeepSeekEnvConfig -AssumeYes:$assumeYes
    if ($ok) { exit 0 } else { exit 1 }
}

if ($RestoreLatest) {
    $ok = Restore-LatestConfigBackup -AssumeYes:$assumeYes
    if ($ok) { exit 0 } else { exit 1 }
}

if ($DeleteSettings) {
    $ok = Remove-SettingsFile -AssumeYes:$assumeYes
    if ($ok) { exit 0 } else { exit 1 }
}

Show-InteractiveMenu

Write-Host ""
Write-Info "日志已保存: $(Get-LogFilePath)"
}
catch {
    $msg = "脚本执行过程中发生未预期的错误：$($_.Exception.Message)"

    if (Get-Command Write-FatalError -ErrorAction SilentlyContinue) {
        Write-FatalError -Message $msg
    }
    else {
        Write-Host "[ERROR] $msg" -ForegroundColor Red
    }

    exit 1
}
