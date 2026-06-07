# ============================================================
# uninstall-config.ps1 - 配置恢复/卸载脚本
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File .\uninstall-config.ps1
#
# 功能:
#   恢复旧配置备份，或清空 DeepSeek API 配置
#   不会删除 Claude Code 本身
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$EntryScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $EntryScriptDir) { $EntryScriptDir = (Get-Location).Path }
. (Join-Path $EntryScriptDir "lib\bootstrap.ps1")
$ScriptDir = Initialize-CcdiScript -ScriptName "uninstall-config"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║           配置恢复/卸载工具                                  ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

Write-Info "此工具可以帮助您:"
Write-Info "  1. 从备份恢复之前的配置文件"
Write-Info "  2. 移除本工具写入的 DeepSeek 配置（保留您自己的其他 env 和配置）"
Write-Info "  3. 删除整个配置文件"
Write-Info ""
Write-Warning "注意: 此工具不会卸载 Claude Code，仅管理配置文件。"
Write-Warning "卸载 Claude Code 请运行: npm uninstall -g @anthropic-ai/claude-code"
Write-Host ""

# 显示当前配置
$currentConfig = Get-DeepSeekConfigStatus
Write-Info "当前配置状态:"
Write-Info "  Base URL: $(if ($currentConfig.BaseUrl) { $currentConfig.BaseUrl } else { '(未设置)' })"
Write-Info "  API Key:  $($currentConfig.MaskedKey)"
Write-Host ""

Write-Host "请选择操作:" -ForegroundColor Cyan
Write-Host "  [1] 从备份恢复配置" -ForegroundColor White
Write-Host "  [2] 仅移除本工具写入的 DeepSeek env（保留其他 env 和配置）" -ForegroundColor White
Write-Host "  [3] 删除整个配置文件" -ForegroundColor White
Write-Host "  [4] 退出" -ForegroundColor White
Write-Host ""

$choice = Read-Host "请输入选项 (1-4)"

# 本工具管理的 DeepSeek env 字段列表
$managedFields = @(
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_MODEL",
    "ANTHROPIC_SMALL_FAST_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "CLAUDE_CODE_SUBAGENT_MODEL",
    "CLAUDE_CODE_EFFORT_LEVEL"
)

switch ($choice) {
    "1" {
        Write-Info "正在查找可用备份..."
        $restoreResult = Restore-ConfigFromBackup
        if ($restoreResult.Success) {
            Write-Success "配置已恢复！"
        }
        else {
            Write-Info $restoreResult.Message
        }
    }
    "2" {
        Write-Warning "即将从配置文件中移除本工具写入的所有 DeepSeek 相关 env 字段。"
        Write-Info "以下字段将被移除: $($managedFields -join ', ')"
        Write-Info "您自己添加的其他 env 字段和配置项（permissions/hooks/mcpServers 等）将保留。"
        if (Confirm-UserChoice -Message "确认移除上述 DeepSeek env 字段？") {
            $configPath = Get-ClaudeConfigFile
            if (Test-Path $configPath) {
                # 修改前必须成功备份，否则停止修改
                $backupResult = Backup-File -FilePath $configPath
                if (-not $backupResult) {
                    Write-Error-Msg "配置文件备份失败，已停止修改，避免破坏用户配置。"
                    Write-Info "请检查 backup/ 目录权限或磁盘空间。"
                    break
                }

                # 读取配置
                $config = Read-JsonFileSafe -FilePath $configPath
                if ($config -and ($config.PSObject.Properties.Name -contains "env") -and $null -ne $config.env) {
                    # 防御：仅当 env 是 PSCustomObject（JSON 对象）时才枚举属性
                    if ($config.env -isnot [System.Management.Automation.PSCustomObject]) {
                        Write-Warning "配置文件中 env 字段类型异常 ($($config.env.GetType().Name))，将安全重建整个 env。"
                        Write-Info "您自己的其他 env 字段未能保留，原始文件已备份。"
                        $envHash = @{}
                        $removedCount = $managedFields.Count
                    }
                    else {
                        # 保留非本工具管理的 env 字段
                        $envHash = @{}
                        $removedCount = 0
                        foreach ($prop in $config.env.PSObject.Properties) {
                            if ($prop.Name -in $managedFields) {
                                $removedCount++
                            }
                            else {
                                $envHash[$prop.Name] = $prop.Value
                            }
                        }
                    }

                    # 重建配置对象
                    $newConfig = [PSCustomObject]@{}
                    foreach ($prop in $config.PSObject.Properties) {
                        if ($prop.Name -ne "env") {
                            Add-Member -InputObject $newConfig -MemberType NoteProperty -Name $prop.Name -Value $prop.Value
                        }
                    }
                    Add-Member -InputObject $newConfig -MemberType NoteProperty -Name "env" -Value ([PSCustomObject]$envHash)

                    # 写入前检查返回值，写回失败不谎报成功
                    $writeOk = Write-JsonFileSafe -FilePath $configPath -Data $newConfig
                    if (-not $writeOk) {
                        Write-Error-Msg "配置写回失败，原备份已保留，请检查磁盘权限或磁盘空间。"
                        break
                    }
                    Write-Success "已移除 $removedCount 个 DeepSeek 相关 env 字段。"
                    Write-Info "您自己的其他 env 字段和配置项已保留。"
                }
                else {
                    Write-Warning "配置文件中没有 env 字段，无需操作。"
                }
            }
            else {
                Write-Info "配置文件不存在，无需操作。"
            }
        }
    }
    "3" {
        Write-Warning "⚠️  即将删除整个配置文件: $(Get-ClaudeConfigFile)"
        Write-Warning "这将移除所有 Claude Code 配置（不仅是 DeepSeek 相关）。"
        if (Confirm-UserChoice -Message "确认删除整个配置文件？此操作不可恢复！") {
            $configPath = Get-ClaudeConfigFile
            if (Test-Path $configPath) {
                # 删除前必须成功备份
                $backupResult = Backup-File -FilePath $configPath
                if (-not $backupResult) {
                    Write-Error-Msg "配置文件备份失败，已停止删除操作。"
                    Write-Info "请检查 backup/ 目录权限或磁盘空间。"
                    break
                }
                Remove-Item -Path $configPath -Force
                Write-Success "配置文件已删除。备份保留在 backup/ 目录。"
            }
            else {
                Write-Info "配置文件不存在，无需操作。"
            }
        }
        else {
            Write-Info "已取消。"
        }
    }
    "4" {
        Write-Info "已退出。"
    }
    default {
        Write-Error-Msg "无效选项。"
    }
}

Write-Host ""
Write-Info "日志已保存: $(Get-LogFilePath)"
