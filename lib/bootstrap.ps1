# ============================================================
# bootstrap.ps1 - 入口脚本初始化
# 统一定位项目根目录、加载公共库并初始化日志
# ============================================================

$script:CcdiLibDir = $PSScriptRoot
$script:CcdiProjectRoot = Split-Path -Parent $script:CcdiLibDir

function Get-CcdiProjectRoot {
    return $script:CcdiProjectRoot
}

. (Join-Path $script:CcdiLibDir "logger.ps1")
. (Join-Path $script:CcdiLibDir "common.ps1")
. (Join-Path $script:CcdiLibDir "state.ps1")
. (Join-Path $script:CcdiLibDir "env-check.ps1")
. (Join-Path $script:CcdiLibDir "config-writer.ps1")

function Initialize-CcdiScript {
    <#
    .SYNOPSIS
        初始化入口脚本所需的公共库和日志。
    .PARAMETER ScriptName
        日志文件名前缀，例如 install、doctor。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName
    )

    Initialize-Logger -LogDirPath (Join-Path $script:CcdiProjectRoot "logs") -ScriptName $ScriptName

    return $script:CcdiProjectRoot
}
