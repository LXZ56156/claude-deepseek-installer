# ============================================================
# scripts/check.ps1 - 轻量 PowerShell 自检
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $PSScriptRoot
Set-Location $RootDir

Write-Host "[check] PowerShell syntax"
$psFiles = Get-ChildItem -Path $RootDir -Filter "*.ps1" -Recurse |
    Where-Object { $_.FullName -notmatch "\\logs\\|\\backup\\" }

foreach ($file in $psFiles) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        throw "PowerShell parse failed: $($file.FullName) - $($errors[0].Message)"
    }
}

Write-Host "[check] load libraries"
. (Join-Path $RootDir "lib\bootstrap.ps1")
$null = Initialize-CcdiScript -ScriptName "check"

Write-Host "[check] Mask-ApiKey"
$key = "sk-1234567890abcdef1234567890abcdef"
$masked = Mask-ApiKey -Key $key
if ($masked -eq $key -or $masked -notmatch "\*\*\*\*") {
    throw "Mask-ApiKey did not mask the key"
}

Write-Host "[check] Merge-SettingsJson"
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ccdi-check-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
try {
    $settingsPath = Join-Path $tempDir "settings.json"
    $existing = [PSCustomObject]@{
        keep = "value"
        env = [PSCustomObject]@{
            ANTHROPIC_AUTH_TOKEN = "old"
            CUSTOM_VAR = "keep-me"
        }
    }
    Write-JsonFileSafe -FilePath $settingsPath -Data $existing | Out-Null

    $merged = Merge-SettingsJson -ExistingPath $settingsPath -NewEnv @{
        ANTHROPIC_AUTH_TOKEN = "new"
        ANTHROPIC_BASE_URL = "https://api.deepseek.com/anthropic"
    }

    if ($merged.keep -ne "value") { throw "non-env field was not preserved" }
    if ($merged.env.CUSTOM_VAR -ne "keep-me") { throw "existing env field was not preserved" }
    if ($merged.env.ANTHROPIC_AUTH_TOKEN -ne "new") { throw "env field was not overwritten" }
}
finally {
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[check] Doctor state guardrails"
$doctorText = Get-Content -Path (Join-Path $RootDir "doctor.ps1") -Raw -Encoding UTF8
if ($doctorText -notmatch '\$script:DoctorState') {
    throw "doctor.ps1 does not use script-level DoctorState"
}
if ($doctorText -match '\$Suggestions \+=') {
    throw "doctor.ps1 still uses scoped Suggestions +="
}

Write-Host "[check] OK"
