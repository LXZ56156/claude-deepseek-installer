# ============================================================
# package-release.ps1 - Backward-compatible Release ZIP entry
# ============================================================

param(
    [string]$Version = "1.3.1",
    [string]$OutputDir = $null,
    [switch]$SkipSha256
)

$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$buildScript = Join-Path $scriptDir "build-release.ps1"

$argsList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $buildScript, "-Version", $Version)
if ($OutputDir) {
    $argsList += @("-OutputDir", $OutputDir)
}
if ($SkipSha256) {
    $argsList += "-SkipSha256"
}

& powershell @argsList
exit $LASTEXITCODE
