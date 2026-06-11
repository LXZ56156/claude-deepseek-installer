# ============================================================
# scripts/check.ps1 - 轻量 PowerShell 自检
# ============================================================

param(
    [switch]$Network,
    [switch]$StrictNetwork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $PSScriptRoot
Set-Location $RootDir

Write-Host "PowerShell: $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)"

$ExcludeDirs = @(
    ".git",
    ".sandbox",
    "logs",
    "backup",
    "reports",
    "release",
    "node_modules"
)

function Test-IsExcludedPath {
    param([string]$Path)

    foreach ($dir in $ExcludeDirs) {
        $escaped = [regex]::Escape($dir)
        if ($Path -match "(^|[\\/])$escaped([\\/]|$)") {
            return $true
        }
    }
    return $false
}

Write-Host "[check] PowerShell syntax"
$psFiles = Get-ChildItem -Path $RootDir -Filter "*.ps1" -Recurse |
    Where-Object { -not (Test-IsExcludedPath $_.FullName) }

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

Write-Host "[check] bootstrap exports"
$requiredCommands = @(
    "Write-Log",
    "Write-Info",
    "Write-Success",
    "Write-Warning",
    "Write-Error-Msg",
    "Write-FatalError",
    "Invoke-CommandSafe",
    "Read-ApiKeyWithMaskedConfirmation",
    "Sanitize-ReportText",
    "Sanitize-PathForReport",
    "Convert-WindowsPathToWslPath",
    "Get-DesktopPath",
    "Get-WindowsVersionInfo",
    "Get-SystemArchitectureInfo",
    "Get-MemoryInfo",
    "Test-MinimumRequirements",
    "Test-ClaudeInstalled",
    "Write-DeepSeekConfig",
    "Get-DeepSeekConfigStatus",
    "Initialize-CcdiState",
    "Update-CcdiState",
    "Read-CcdiState",
    "Get-CcdiStateValue",
    "Test-ClaudeCommandExisting",
    "Test-HttpEndpointReachable",
    "Test-ClaudeOfficialInstallNetwork",
    "Test-NpmMirrorClaudeCodeNetwork",
    "Install-ClaudeCodeNative",
    "Install-ClaudeCodeNpmMirror",
    "Install-ClaudeCodeAuto",
    "Invoke-ClaudeDoctorSafe",
    "Invoke-ClaudeDoctorInteractiveSafe",
    "Clear-StaleClaudeDoctorProcesses"
)

foreach ($cmd in $requiredCommands) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Bootstrap 导出检查失败：未找到 $cmd"
    }
}

Write-Host "[check] Mask-ApiKey"
$key = "sk-" + ("x" * 32)
$masked = Mask-ApiKey -Key $key
if ($masked -eq $key -or $masked -notmatch "\*\*\*\*") {
    throw "Mask-ApiKey did not mask the key"
}

Write-Host "[check] Path risk detection"
$pathRiskTempRoot = if ($env:TEMP) {
    $env:TEMP
}
else {
    [System.IO.Path]::GetTempPath().TrimEnd('\', '/')
}

$pathRiskCases = @(
    @{
        Name          = "Recommended path"
        Path          = "D:\ClaudeDeepSeek"
        ShouldBlock   = $false
        ExpectedLevel = "INFO"
    },
    @{
        Name          = "Normal temp path"
        Path          = Join-Path $pathRiskTempRoot "ClaudeDeepSeek"
        ShouldBlock   = $false
        ExpectedLevel = "WARN"
    },
    @{
        Name          = "WinRAR temp path"
        Path          = Join-Path $pathRiskTempRoot 'Rar$EXa123\ClaudeDeepSeek'
        ShouldBlock   = $true
        ExpectedLevel = "BLOCK"
    },
    @{
        Name          = "7Zip temp path"
        Path          = Join-Path $pathRiskTempRoot "7zO123456\ClaudeDeepSeek"
        ShouldBlock   = $true
        ExpectedLevel = "BLOCK"
    },
    @{
        Name          = "Explorer Temp1 zip path"
        Path          = Join-Path $pathRiskTempRoot "Temp1_package.zip\ClaudeDeepSeek"
        ShouldBlock   = $true
        ExpectedLevel = "BLOCK"
    },
    @{
        Name          = "Chinese only path"
        Path          = "D:\中文路径\Claude"
        ShouldBlock   = $false
        ExpectedLevel = "INFO"
    },
    @{
        Name          = "Space path"
        Path          = "D:\中文 路径\Claude"
        ShouldBlock   = $false
        ExpectedLevel = "WARN"
    },
    @{
        Name          = "WSL UNC path"
        Path          = "\\wsl.localhost\Ubuntu\home\user\repo"
        ShouldBlock   = $false
        ExpectedLevel = "WARN"
    },
    @{
        Name          = "Non-temp 7zip-like folder"
        Path          = "D:\tools\7zip-helper\Claude"
        ShouldBlock   = $false
        ExpectedLevel = $null
    }
)

foreach ($case in $pathRiskCases) {
    $pathRisk = Test-UserPathRisk -PathToCheck $case.Path
    if ($pathRisk.IsBlocked -ne $case.ShouldBlock) {
        throw "Path risk failed: $($case.Name). Path=$($case.Path), IsBlocked=$($pathRisk.IsBlocked), expected=$($case.ShouldBlock), RiskLevel=$($pathRisk.RiskLevel)"
    }
    if ($case.ExpectedLevel -and $pathRisk.RiskLevel -ne $case.ExpectedLevel) {
        throw "Path risk level failed: $($case.Name). RiskLevel=$($pathRisk.RiskLevel), expected=$($case.ExpectedLevel)"
    }
    Write-Host "[check]   $($case.Name): $($pathRisk.RiskLevel), blocked=$($pathRisk.IsBlocked)"
}

Write-Host "[check] Empty env StrictMode safety"
$emptyEnvRoot = Join-Path $RootDir ".sandbox\check-empty-env"
$emptyEnvHome = Join-Path $emptyEnvRoot "userprofile"
$emptyEnvClaude = Join-Path $emptyEnvHome ".claude"
$emptyEnvSettings = Join-Path $emptyEnvClaude "settings.json"
$oldEmptyEnvTestMode = $env:CCDI_TEST_MODE
$oldEmptyEnvUserProfile = $env:CCDI_TEST_USERPROFILE

Remove-Item $emptyEnvRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $emptyEnvClaude | Out-Null

try {
    $env:CCDI_TEST_MODE = "1"
    $env:CCDI_TEST_USERPROFILE = $emptyEnvHome

    [System.IO.File]::WriteAllText(
        $emptyEnvSettings,
        "{`"env`":{}}",
        (New-Object System.Text.UTF8Encoding($false))
    )

    $status = Get-DeepSeekConfigStatus
    if ($status.IsConfigured) {
        throw "Empty env should not be configured"
    }
    if ($status.ErrorMessage -notmatch "env 字段为空对象") {
        throw "Empty env should report empty object, got: $($status.ErrorMessage)"
    }

    $apiKey = Get-ApiKeyFromConfig
    if ($null -ne $apiKey) {
        throw "Empty env should not return API key"
    }
}
finally {
    if ($oldEmptyEnvTestMode) { $env:CCDI_TEST_MODE = $oldEmptyEnvTestMode } else { Remove-Item Env:\CCDI_TEST_MODE -ErrorAction SilentlyContinue }
    if ($oldEmptyEnvUserProfile) { $env:CCDI_TEST_USERPROFILE = $oldEmptyEnvUserProfile } else { Remove-Item Env:\CCDI_TEST_USERPROFILE -ErrorAction SilentlyContinue }
    Remove-Item $emptyEnvRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "[check] Empty env StrictMode safety OK"

Write-Host "[check] Partial CCDI state StrictMode safety"
$partialStateRoot = Join-Path $RootDir ".sandbox\check-partial-state"
$partialStateHome = Join-Path $partialStateRoot "userprofile"
$partialStateDir = Join-Path $partialStateHome ".claude-deepseek-installer"
$partialStateFile = Join-Path $partialStateDir "state.json"
$partialStateRunner = Join-Path $partialStateRoot "show-status-only.ps1"

$oldPartialStateTestMode = $env:CCDI_TEST_MODE
$oldPartialStateUserProfile = $env:CCDI_TEST_USERPROFILE

Remove-Item $partialStateRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $partialStateDir | Out-Null

try {
    $env:CCDI_TEST_MODE = "1"
    $env:CCDI_TEST_USERPROFILE = $partialStateHome

    [System.IO.File]::WriteAllText(
        $partialStateFile,
        "{`"claudeInstallMethod`":`"existing`",`"claudeWasAlreadyInstalled`":true,`"claudeInstallStatus`":`"skipped_existing`"}",
        (New-Object System.Text.UTF8Encoding($false))
    )

    $state = Read-CcdiState
    $method = Get-CcdiStateValue -State $state -Name "claudeInstallMethod" -Default "(未知)"
    $installedAt = Get-CcdiStateValue -State $state -Name "installedAt" -Default "(未记录)"

    if ($method -ne "existing") {
        throw "Partial state method read failed"
    }

    if ($installedAt -ne "(未记录)") {
        throw "Missing installedAt should return default"
    }

    Set-Content -Path $partialStateRunner -Encoding UTF8 -Value @"
param([string]`$ProfilePath)
`$env:CCDI_TEST_MODE = "1"
`$env:CCDI_TEST_USERPROFILE = `$ProfilePath
& "$RootDir\uninstall-config.ps1" -ShowStatusOnly
exit `$LASTEXITCODE
"@

    $showStatusOutput = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $partialStateRunner $partialStateHome 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "uninstall-config -ShowStatusOnly failed with partial state"
    }

    $latestUninstallLog = Get-ChildItem -Path (Join-Path $RootDir "logs") -Filter "uninstall-config-*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    $showStatusText = if ($latestUninstallLog) {
        Get-Content -Path $latestUninstallLog.FullName -Raw -Encoding UTF8
    }
    else {
        ($showStatusOutput | Out-String)
    }
    if ($showStatusText -notmatch "安装方式: existing") {
        throw "uninstall-config -ShowStatusOnly did not read partial state"
    }
    if ($showStatusText -notmatch "安装时间: \(未记录\)") {
        throw "uninstall-config -ShowStatusOnly did not show default installedAt"
    }
}
finally {
    if ($oldPartialStateTestMode) { $env:CCDI_TEST_MODE = $oldPartialStateTestMode } else { Remove-Item Env:\CCDI_TEST_MODE -ErrorAction SilentlyContinue }
    if ($oldPartialStateUserProfile) { $env:CCDI_TEST_USERPROFILE = $oldPartialStateUserProfile } else { Remove-Item Env:\CCDI_TEST_USERPROFILE -ErrorAction SilentlyContinue }
    Remove-Item $partialStateRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[check] Partial CCDI state StrictMode safety OK"

Write-Host "[check] API test exception handling"
$oldApiStatus = $env:CCDI_TEST_API_STATUS
try {
    Remove-Item Env:\CCDI_TEST_API_STATUS -ErrorAction SilentlyContinue
    $apiFailure = Test-DeepSeekApiAnthropic `
        -ApiKey ("sk-" + ("x" * 32)) `
        -BaseUrl "http://127.0.0.1:1/anthropic" `
        -Model "deepseek-v4-flash"

    if ($apiFailure.Success) {
        throw "Local closed-port API test should not succeed"
    }
    if ([string]::IsNullOrWhiteSpace($apiFailure.Error)) {
        throw "API failure should return a structured error message"
    }
}
finally {
    if ($oldApiStatus) { $env:CCDI_TEST_API_STATUS = $oldApiStatus } else { Remove-Item Env:\CCDI_TEST_API_STATUS -ErrorAction SilentlyContinue }
}
Write-Host "[check] API test exception handling OK"

function Write-NetworkCheckResult {
    param(
        [string]$Name,
        [bool]$Reachable,
        [string]$Detail
    )

    if ($Reachable) {
        Write-Host "[check]     $Name reachable: $Detail"
        return
    }

    $message = "$Name unreachable: $Detail"
    if ($StrictNetwork) {
        throw $message
    }
    Write-Host "[check]     WARN: $message"
}

Write-Host "[check] Invoke-CommandSafe Windows command execution"
$psResult = Invoke-CommandSafe -Command "powershell.exe" -Arguments @(
    "-NoProfile", "-Command", "Write-Output ok; exit 0"
)
if (-not $psResult.Success -or $psResult.ExitCode -ne 0 -or $psResult.Output.Trim() -ne "ok") {
    throw "Invoke-CommandSafe failed to capture powershell.exe success"
}

$tempCmdDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ccdi-check-cmd-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempCmdDir -Force | Out-Null
try {
    $tempCmd = Join-Path $tempCmdDir "ok.cmd"
    Set-Content -Path $tempCmd -Encoding ASCII -Value "@echo off`r`necho cmd-ok`r`nexit /b 0"
    $cmdResult = Invoke-CommandSafe -Command $tempCmd
    if (-not $cmdResult.Success -or $cmdResult.ExitCode -ne 0 -or $cmdResult.Output.Trim() -ne "cmd-ok") {
        throw "Invoke-CommandSafe failed to execute .cmd files"
    }
}
finally {
    Remove-Item -Path $tempCmdDir -Recurse -Force -ErrorAction SilentlyContinue
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

Write-Host "[check] backup filename precision"
$commonText = Get-Content -Path (Join-Path $RootDir "lib\common.ps1") -Raw -Encoding UTF8
if ($commonText -notmatch 'yyyyMMdd-HHmmss-fff') {
    throw "Backup-File must use millisecond precision to avoid overwriting backups created in the same second"
}

Write-Host "[check] Doctor state guardrails"
$doctorText = Get-Content -Path (Join-Path $RootDir "doctor.ps1") -Raw -Encoding UTF8
if ($doctorText -notmatch '\$script:DoctorState') {
    throw "doctor.ps1 does not use script-level DoctorState"
}
if ($doctorText -match '\$Suggestions \+=') {
    throw "doctor.ps1 still uses scoped Suggestions +="
}
$requiredDoctorCountPatterns = @(
    '\$okCount\s*=\s*@\(\$script:DoctorState\.CheckResults\s*\|\s*Where-Object\s*\{\s*\$_\.Status\s+-eq\s+"OK"\s*\}\)\.Count',
    '\$warnCount\s*=\s*@\(\$script:DoctorState\.CheckResults\s*\|\s*Where-Object\s*\{\s*\$_\.Status\s+-eq\s+"WARN"\s*\}\)\.Count',
    '\$errCount\s*=\s*@\(\$script:DoctorState\.CheckResults\s*\|\s*Where-Object\s*\{\s*\$_\.Status\s+-eq\s+"ERROR"\s*\}\)\.Count'
)
foreach ($pattern in $requiredDoctorCountPatterns) {
    if ($doctorText -notmatch $pattern) {
        throw "doctor.ps1 summary counts must wrap pipeline results in @(...).Count"
    }
}

Write-Host "[check] Claude doctor interactive invocation"
$claudeInstallText = Get-Content -Path (Join-Path $RootDir "lib\claude-install.ps1") -Raw -Encoding UTF8
$commonText = Get-Content -Path (Join-Path $RootDir "lib\common.ps1") -Raw -Encoding UTF8
$doctorText = Get-Content -Path (Join-Path $RootDir "doctor.ps1") -Raw -Encoding UTF8

# 1. Invoke-ClaudeDoctorInteractiveSafe exists with required fields
if ($claudeInstallText -notmatch 'function Invoke-ClaudeDoctorInteractiveSafe') {
    throw "Invoke-ClaudeDoctorInteractiveSafe function not found in lib/claude-install.ps1"
}
if ($claudeInstallText -notmatch 'TimedOut\s*=\s*\$false') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must include TimedOut field in result"
}
if ($claudeInstallText -notmatch 'DurationMs') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must include DurationMs field in result"
}

# 2. doctor.ps1 calls Invoke-ClaudeDoctorInteractiveSafe, not Invoke-CommandSafe for claude doctor
if ($doctorText -notmatch 'Invoke-ClaudeDoctorInteractiveSafe') {
    throw "doctor.ps1 must use Invoke-ClaudeDoctorInteractiveSafe for claude doctor"
}
if ($doctorText -match 'Invoke-CommandSafe\s+-Command\s+"claude"\s+-Arguments\s+@\("doctor"\)') {
    throw "doctor.ps1 must NOT use Invoke-CommandSafe to run claude doctor"
}

# 3. doctor.ps1 handles TimedOut separately
if ($doctorText -notmatch 'claudeDoctor\.TimedOut') {
    throw "doctor.ps1 must check claudeDoctor.TimedOut for timeout-specific messaging"
}
if ($doctorText -notmatch '超时，已终止；这不代表 Claude Code 安装失败') {
    throw "doctor.ps1 must clearly state that claude doctor timeout does not mean install failure"
}

# 4. Invoke-CommandSafe uses taskkill /T /F for process tree termination
if ($commonText -notmatch 'taskkill\.exe\s+/PID') {
    throw "Invoke-CommandSafe must use taskkill.exe for timeout process termination"
}
if ($commonText -notmatch '/T\s+/F') {
    throw "Invoke-CommandSafe must use taskkill /T /F to kill process tree"
}

# 5. Invoke-CommandSafe reads temp files BEFORE deleting on timeout
# The "partial stdout/stderr read before cleanup" pattern must exist
if ($commonText -notmatch '超时部分 stdout') {
    throw "Invoke-CommandSafe must read stdout temp file for partial content before timeout cleanup"
}
if ($commonText -notmatch '超时部分 stderr') {
    throw "Invoke-CommandSafe must read stderr temp file for partial content before timeout cleanup"
}

# 6. Clear-StaleClaudeDoctorProcesses exists with proper filtering
if ($claudeInstallText -notmatch 'function Clear-StaleClaudeDoctorProcesses') {
    throw "Clear-StaleClaudeDoctorProcesses function not found in lib/claude-install.ps1"
}
if ($claudeInstallText -notmatch '\$\w+\.CommandLine\s+-match\s+') {
    throw "Clear-StaleClaudeDoctorProcesses must filter by CommandLine to avoid killing non-doctor claude"
}
if ($claudeInstallText -notmatch 'doctor') {
    # Already matched above; this is a sanity check
}

# 7. Invoke-ClaudeDoctorInteractiveSafe calls Clear-StaleClaudeDoctorProcesses
if ($claudeInstallText -notmatch 'Clear-StaleClaudeDoctorProcesses') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must call Clear-StaleClaudeDoctorProcesses"
}

# 8. doctor.ps1 TestSafe path for claude doctor
if ($doctorText -notmatch 'CCDI_TEST_MODE\s+-eq\s+"1"') {
    throw "doctor.ps1 should skip claude doctor when CCDI_TEST_MODE=1"
}

# 9. Invoke-ClaudeDoctorSafe must NOT contain Invoke-CommandSafe calling claude doctor
if ($claudeInstallText -match 'Invoke-ClaudeDoctorSafe[\s\S]{0,500}Invoke-CommandSafe') {
    throw "Invoke-ClaudeDoctorSafe must NOT use Invoke-CommandSafe internally; delegate to Invoke-ClaudeDoctorInteractiveSafe"
}

# 10. lib/claude-install.ps1 must NOT contain Invoke-CommandSafe + claude + doctor combined
# Check each non-comment line: no line should have both Invoke-CommandSafe, claude, and doctor
$claudeInstallLines = Get-Content -Path (Join-Path $RootDir "lib\claude-install.ps1") -Encoding UTF8
foreach ($line in $claudeInstallLines) {
    if ($line -match '^\s*#' -or $line -match '^\s*<#' -or $line -match '^\s*\.') { continue }
    if ($line -match 'Invoke-CommandSafe' -and $line -match '\bclaude\b' -and $line -match '\bdoctor\b') {
        throw "lib/claude-install.ps1 must NOT combine Invoke-CommandSafe with claude and doctor on same line: $line"
    }
}

# 11. Invoke-ClaudeDoctorSafe must delegate to Invoke-ClaudeDoctorInteractiveSafe
if ($claudeInstallText -notmatch 'function Invoke-ClaudeDoctorSafe[\s\S]{0,300}Invoke-ClaudeDoctorInteractiveSafe') {
    throw "Invoke-ClaudeDoctorSafe must delegate to Invoke-ClaudeDoctorInteractiveSafe"
}

# 12. Clear-StaleClaudeDoctorProcesses must support -ParentPid for scoped cleanup
if ($claudeInstallText -notmatch '\[int\]\$ParentPid') {
    throw "Clear-StaleClaudeDoctorProcesses must have -ParentPid parameter for scoped cleanup"
}
if ($claudeInstallText -notmatch '\$ParentPid\s+-gt\s+0') {
    throw "Clear-StaleClaudeDoctorProcesses must filter by ParentPid when specified"
}

# 13. Timeout post-cleanup must use -ParentPid (not -Force on global scope)
if ($claudeInstallText -notmatch 'Clear-StaleClaudeDoctorProcesses\s+-ParentPid') {
    throw "Timeout post-cleanup must use Clear-StaleClaudeDoctorProcesses -ParentPid for scoped cleanup"
}

# 14. Invoke-ClaudeDoctorInteractiveSafe must handle Start-Job failure gracefully
if ($claudeInstallText -notmatch 'watchdogAvailable') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must handle Start-Job failure with watchdogAvailable flag"
}
if ($claudeInstallText -notmatch 'Start-Job 创建 watchdog 失败') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must log warning when Start-Job fails"
}

# 15. Start-Job failure branch must NOT execute & $claudePath doctor (must skip instead)
# When watchdogAvailable is false, the code must return early with watchdog_unavailable_skipped
if ($claudeInstallText -notmatch 'watchdog_unavailable_skipped') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must return watchdog_unavailable_skipped when Start-Job is unavailable"
}

# 16. "无超时保护下运行（最多等待 120 秒）" must NOT appear (unfulfilled promise)
if ($claudeInstallText -match '无超时保护下运行') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must NOT promise timeout protection it cannot deliver"
}

# 17. Start-Job failure must log skip reason with "避免诊断流程卡死"
if ($claudeInstallText -notmatch '已跳过 claude doctor，避免诊断流程卡死') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must log that claude doctor was skipped to avoid hang"
}

# 18. Invoke-ClaudeDoctorSafe must map watchdog_unavailable_skipped to skipped_watchdog_unavailable
if ($claudeInstallText -notmatch 'skipped_watchdog_unavailable') {
    throw "Invoke-ClaudeDoctorSafe must map watchdog_unavailable_skipped to skipped_watchdog_unavailable status"
}

# 19. doctor.ps1 must handle watchdog_unavailable_skipped as SKIP
if ($doctorText -notmatch 'watchdog_unavailable_skipped') {
    throw "doctor.ps1 must handle watchdog_unavailable_skipped error from Invoke-ClaudeDoctorInteractiveSafe"
}
if ($doctorText -notmatch '超时保护不可用.*Start-Job 被禁用') {
    throw "doctor.ps1 must clearly explain that Start-Job disabled caused the skip"
}

Write-Host "[check] Claude doctor interactive invocation OK"

Write-Host "[check] Visible install command UX"
$claudeInstallText = Get-Content -Path (Join-Path $RootDir "lib\claude-install.ps1") -Raw -Encoding UTF8

# 20. Invoke-VisibleInstallCommand exists with required properties
if ($claudeInstallText -notmatch 'function Invoke-VisibleInstallCommand') {
    throw "Invoke-VisibleInstallCommand function not found in lib/claude-install.ps1"
}
if ($claudeInstallText -notmatch 'NoNewWindow\s*=\s*\$true' -or $claudeInstallText -notmatch 'PassThru\s*=\s*\$true') {
    throw "Invoke-VisibleInstallCommand must use Start-Process with NoNewWindow and PassThru"
}
if ($claudeInstallText -notmatch 'taskkill\.exe\s+/PID.*\/T\s+\/F') {
    throw "Invoke-VisibleInstallCommand must use taskkill /T /F for process tree kill on timeout"
}
if ($claudeInstallText -notmatch 'Stop-Process.*-Force') {
    throw "Invoke-VisibleInstallCommand must have Stop-Process fallback"
}

# 21. Install-NodeJsViaWinget delegates to Invoke-VisibleInstallCommand (NOT Invoke-CommandSafe)
if ($claudeInstallText -notmatch 'Install-NodeJsViaWinget[\s\S]{0,800}Invoke-VisibleInstallCommand') {
    throw "Install-NodeJsViaWinget must delegate to Invoke-VisibleInstallCommand"
}

# 22. Install-ClaudeCodeNpmMirror must NOT use Invoke-CommandSafe for npm install
if ($claudeInstallText -match 'Install-ClaudeCodeNpmMirror[\s\S]{0,800}Invoke-CommandSafe\s+-Command\s+"npm"') {
    throw "Install-ClaudeCodeNpmMirror must NOT use Invoke-CommandSafe for npm install; use Invoke-VisibleInstallCommand"
}
if ($claudeInstallText -notmatch 'Install-ClaudeCodeNpmMirror[\s\S]{0,1500}Invoke-VisibleInstallCommand') {
    throw "Install-ClaudeCodeNpmMirror must use Invoke-VisibleInstallCommand for npm install"
}

# 23. Install-ClaudeCodeNative execution phase must NOT use Invoke-CommandSafe
if ($claudeInstallText -match 'Install-ClaudeCodeNative[\s\S]{0,1500}Invoke-CommandSafe\s+-Command\s+"powershell"[\s\S]{0,300}-File\s+\$tempInstallScript') {
    throw "Install-ClaudeCodeNative execution must NOT use Invoke-CommandSafe; use Invoke-VisibleInstallCommand"
}
if ($claudeInstallText -notmatch 'Install-ClaudeCodeNative[\s\S]{0,1500}Invoke-VisibleInstallCommand') {
    throw "Install-ClaudeCodeNative must use Invoke-VisibleInstallCommand for script execution"
}

# 24. No double-assignment: else branch of winget install if-expression must NOT have "$installResult ="
if ($claudeInstallText -notmatch '\}\s*else\s*\{\s*Install-NodeJsViaWinget') {
    # This is a soft check - the else branch should directly call, not assign
    if ($claudeInstallText -match '\}\s*else\s*\{\s*\$installResult\s*=\s*Install-NodeJsViaWinget') {
        throw "winget install else branch has redundant \$installResult = assignment"
    }
}

# 25. repair-deps.ps1 must NOT use Invoke-CommandSafe for winget install
$repairDepsText = Get-Content -Path (Join-Path $RootDir "repair-deps.ps1") -Raw -Encoding UTF8
if ($repairDepsText -match 'Invoke-CommandSafe\s+-Command\s+"winget"') {
    throw "repair-deps.ps1 must NOT use Invoke-CommandSafe for winget install; use Install-NodeJsViaWinget"
}
if ($repairDepsText -notmatch 'Install-NodeJsViaWinget') {
    throw "repair-deps.ps1 must call Install-NodeJsViaWinget for Node.js installation"
}

# 26. Short timeouts for version checks
$envCheckText = Get-Content -Path (Join-Path $RootDir "lib\env-check.ps1") -Raw -Encoding UTF8
# All version check commands should have explicit TimeoutSec <= 10
$quickTimeoutPatterns = @(
    @{ Name = "git --version"; Pattern = 'git".*--version.*-TimeoutSec\s+(\d+)'; MaxSec = 10 },
    @{ Name = "code --version"; Pattern = 'code".*--version.*-TimeoutSec\s+(\d+)'; MaxSec = 10 },
    @{ Name = "code --list-extensions"; Pattern = '--list-extensions.*-TimeoutSec\s+(\d+)'; MaxSec = 10 },
    @{ Name = "wsl --version"; Pattern = 'wsl".*--version.*-TimeoutSec\s+(\d+)'; MaxSec = 10 },
    @{ Name = "wsl -l -v"; Pattern = '-l",\s*"-v.*-TimeoutSec\s+(\d+)'; MaxSec = 10 },
    @{ Name = "claude --version"; Pattern = 'claude".*--version.*-TimeoutSec\s+(\d+)'; MaxSec = 10 },
    @{ Name = "node --version"; Pattern = 'node".*--version.*-TimeoutSec\s+(\d+)'; MaxSec = 10 },
    @{ Name = "npm --version"; Pattern = 'npm".*--version.*-TimeoutSec\s+(\d+)'; MaxSec = 10 }
)
foreach ($p in $quickTimeoutPatterns) {
    if ($envCheckText -match $p.Pattern) {
        $actualSec = [int]$matches[1]
        if ($actualSec -gt $p.MaxSec) {
            throw "$($p.Name) timeout is ${actualSec}s, should be <= $($p.MaxSec)s"
        }
    }
}

Write-Host "[check] Install flow: no claude doctor during install"

# 27. Install-ClaudeCodeAuto must NOT call Invoke-ClaudeDoctorSafe or Invoke-ClaudeDoctorInteractiveSafe
if ($claudeInstallText -match 'function Install-ClaudeCodeAuto[\s\S]{0,5000}Invoke-ClaudeDoctorSafe') {
    throw "Install-ClaudeCodeAuto must NOT call Invoke-ClaudeDoctorSafe; claude doctor is diagnostic-only"
}
if ($claudeInstallText -match 'function Install-ClaudeCodeAuto[\s\S]{0,5000}Invoke-ClaudeDoctorInteractiveSafe') {
    throw "Install-ClaudeCodeAuto must NOT call Invoke-ClaudeDoctorInteractiveSafe; claude doctor is diagnostic-only"
}

# 28. Native Install failure must show user-friendly message, NOT PowerShell stack traces
if ($claudeInstallText -notmatch 'Claude 官方安装通道执行失败，正在自动切换国内 npm 镜像安装') {
    throw "Native Install failure must show user-friendly message about automatic npm mirror fallback"
}
if ($claudeInstallText -notmatch '这通常是官方下载通道不稳定或被网络拦截，不代表安装失败') {
    throw "Native Install failure must reassure user that install has not failed"
}

# 29. Native Install error detail must be logged, not displayed to user
if ($claudeInstallText -notmatch 'Write-Log\s+"ERROR"\s+"Native Install 失败详情') {
    throw "Native Install failure details must go to Write-Log, not user display"
}

# 30. Invoke-ClaudeDoctorInteractiveSafe must NOT pollute return stream with claude doctor stdout
if ($claudeInstallText -match '&\s+\$claudePath\s+doctor\s*$' -and $claudeInstallText -notmatch 'Out-Host') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must pipe claude doctor output to Out-Host to prevent return stream pollution"
}

# 31. Invoke-VisibleFileDownload must exist
if ($claudeInstallText -notmatch 'function Invoke-VisibleFileDownload') {
    throw "Invoke-VisibleFileDownload function not found in lib/claude-install.ps1"
}

# 32. Native Install download must NOT use Invoke-CommandSafe
if ($claudeInstallText -match 'Install-ClaudeCodeNative[\s\S]{0,2000}Invoke-CommandSafe[\s\S]{0,200}Invoke-RestMethod') {
    throw "Install-ClaudeCodeNative download must NOT use Invoke-CommandSafe; use Invoke-VisibleFileDownload"
}

# 33. Native Install download must use Invoke-VisibleFileDownload
if ($claudeInstallText -notmatch 'Install-ClaudeCodeNative[\s\S]{0,2000}Invoke-VisibleFileDownload') {
    throw "Install-ClaudeCodeNative must use Invoke-VisibleFileDownload for script download"
}

# 34. Invoke-VisibleFileDownload function default AND all call sites must use TimeoutSec <= 30
# 34a. Function definition default
if ($claudeInstallText -match 'Invoke-VisibleFileDownload[\s\S]{0,300}\[int\]\$TimeoutSec\s*=\s*([4-9]\d|\d{3,})') {
    throw "Invoke-VisibleFileDownload function default TimeoutSec must be <= 30, found $($matches[1])"
}
# 34b. All call sites
$downloadCalls = [regex]::Matches($claudeInstallText, 'Invoke-VisibleFileDownload[\s\S]{0,300}?-TimeoutSec\s+(\d+)')
foreach ($dc in $downloadCalls) {
    $val = [int]$dc.Groups[1].Value
    if ($val -gt 30) {
        throw "Invoke-VisibleFileDownload call site has TimeoutSec $val (must be <= 30)"
    }
}

# 35. Download failure must NOT show PowerShell stack traces in the main UI
#    The friendly fallback message must exist in the caller
if ($claudeInstallText -notmatch 'Native Install 下载失败') {
    throw "Install-ClaudeCodeNative must log download failure details (not show to user)"
}

Write-Host "[check] Install flow checks OK"

Write-Host "[check] Visible install command UX OK"

Write-Host "[check] uninstall backup listing"
$uninstallText = Get-Content -Path (Join-Path $RootDir "uninstall-config.ps1") -Raw -Encoding UTF8
if ($uninstallText -match '\[void\]\s*\(\s*Show-ConfigBackups\s*\)') {
    throw "uninstall-config.ps1 suppresses -ListBackups output"
}
if ($uninstallText -notmatch '\$backups\s*=\s*@\(Get-ConfigBackups\)') {
    throw "uninstall-config.ps1 must wrap Get-ConfigBackups in @() before counting"
}
if ($uninstallText -match 'Sort-Object\s+LastWriteTime') {
    throw "uninstall-config.ps1 must not sort backups by LastWriteTime because Copy-Item preserves source timestamps"
}

Write-Host "[check] .cmd launcher encoding"
$cmdFiles = @(
    (Join-Path $RootDir "开始安装.cmd"),
    (Join-Path $RootDir "一键诊断.cmd"),
    (Join-Path $RootDir "恢复或卸载配置.cmd"),
    (Join-Path $RootDir "Start-Install.cmd"),
    (Join-Path $RootDir "Run-Diagnostics.cmd"),
    (Join-Path $RootDir "Restore-Config.cmd")
)
foreach ($cmdFile in $cmdFiles) {
    if (-not (Test-Path $cmdFile)) {
        throw "$([System.IO.Path]::GetFileName($cmdFile)) missing"
    }
    $bytes = [System.IO.File]::ReadAllBytes($cmdFile)
    # BOM check: first 3 bytes must not be EF BB BF
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "$([System.IO.Path]::GetFileName($cmdFile)) has UTF-8 BOM (will garble Chinese path on CMD)"
    }
    # ASCII check: no byte > 0x7F (all .cmd content must be pure ASCII)
    $nonAscii = $bytes | Where-Object { $_ -gt 0x7F }
    if ($nonAscii) {
        throw "$([System.IO.Path]::GetFileName($cmdFile)) contains non-ASCII bytes (will garble on CMD)"
    }
}
Write-Host "[check] .cmd launchers: no BOM, pure ASCII"

# ============================================================
# 安装安全与返回结构检查（全部在 CCDI_TEST_MODE=1 下运行）
#
# 覆盖内容:
#   函数存在性检查 + TestSafe 安全检查 + 字段 shape 检查
#   + 可选真实网络检查（需传入 -Network）
#
# 未覆盖的完整网络 fallback 分支（需真机或后续 mock 验证）:
#   官方不可用 → npm_npmmirror
#   官方安装失败 → fallback npm_npmmirror
#   Node/npm 缺失 → failed_missing_node_or_npm
#   npmmirror 不可达 → failed_npmmirror_unreachable
#   existing_broken → 进入修复路径
# ============================================================
Write-Host "[check] Claude install safety and structure checks (TestSafe mode)"

# 保存原始环境变量，测试结束后恢复
$origTestMode = $env:CCDI_TEST_MODE
$origUserProfile = $env:CCDI_TEST_USERPROFILE
$origTestDesktop = $env:CCDI_TEST_DESKTOP
$origApiKey = $env:CCDI_API_KEY

try {
    $env:CCDI_TEST_MODE = "1"

    $sandboxDir = Join-Path $RootDir ".sandbox"
    $testUserProfile = Join-Path $sandboxDir "check-test-userprofile"
    $testDesktop = Join-Path $sandboxDir "check-test-desktop"

    # 清理上次残留
    if (Test-Path $testUserProfile) { Remove-Item $testUserProfile -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $testDesktop) { Remove-Item $testDesktop -Recurse -Force -ErrorAction SilentlyContinue }

    New-Item -ItemType Directory -Path $testUserProfile -Force | Out-Null
    New-Item -ItemType Directory -Path $testDesktop -Force | Out-Null
    $env:CCDI_TEST_USERPROFILE = $testUserProfile
    $env:CCDI_TEST_DESKTOP = $testDesktop

    # ----------------------------------------------------------
    # Test 1: Test-ClaudeCommandExisting returns Usable field
    # ----------------------------------------------------------
    Write-Host "[check]   Test 1: Test-ClaudeCommandExisting has Usable field"
    $t1 = Test-ClaudeCommandExisting
    if ($t1.Keys -notcontains "Usable") {
        throw "Test-ClaudeCommandExisting missing Usable field"
    }
    if ($t1.Keys -notcontains "Exists") {
        throw "Test-ClaudeCommandExisting missing Exists field"
    }
    Write-Host "[check]     Exists=$($t1.Exists), Usable=$($t1.Usable)"

    # ----------------------------------------------------------
    # Test 2: Invoke-ClaudeDoctorSafe -TestSafe skips real call
    # ----------------------------------------------------------
    Write-Host "[check]   Test 2: Invoke-ClaudeDoctorSafe -TestSafe skips real claude doctor"
    $t2 = Invoke-ClaudeDoctorSafe -TestSafe
    if ($t2.Success) {
        throw "Invoke-ClaudeDoctorSafe -TestSafe should return Success=false, got Success=true"
    }
    if ($t2.Output -ne "skipped_test_safe") {
        throw "Invoke-ClaudeDoctorSafe -TestSafe should return Output=skipped_test_safe, got: $($t2.Output)"
    }
    Write-Host "[check]     Output=$($t2.Output) (correctly skipped)"

    # Invoke-ClaudeDoctorSafe without -TestSafe but WITH CCDI_TEST_MODE=1 should also skip
    Write-Host "[check]   Test 2b: Invoke-ClaudeDoctorSafe (no TestSafe param, but CCDI_TEST_MODE=1)"
    $t2b = Invoke-ClaudeDoctorSafe
    if ($t2b.Output -ne "skipped_test_safe") {
        throw "Invoke-ClaudeDoctorSafe with CCDI_TEST_MODE=1 should auto-skip, got: $($t2b.Output)"
    }
    Write-Host "[check]     Auto-detected CCDI_TEST_MODE, correctly skipped"

    # ----------------------------------------------------------
    # Test 2c: Invoke-ClaudeDoctorInteractiveSafe -TestSafe skips real call
    # ----------------------------------------------------------
    Write-Host "[check]   Test 2c: Invoke-ClaudeDoctorInteractiveSafe -TestSafe skips"
    $t2c = Invoke-ClaudeDoctorInteractiveSafe -TestSafe -TimeoutSec 5
    if ($t2c.Success) {
        throw "Invoke-ClaudeDoctorInteractiveSafe -TestSafe should return Success=false, got Success=true"
    }
    if ($t2c.Error -ne "skipped_test_safe") {
        throw "Invoke-ClaudeDoctorInteractiveSafe -TestSafe should return Error=skipped_test_safe, got: $($t2c.Error)"
    }
    Write-Host "[check]     correctly skipped, Error=$($t2c.Error)"

    # Test 2d: Invoke-ClaudeDoctorInteractiveSafe with CCDI_TEST_MODE=1 auto-skips
    Write-Host "[check]   Test 2d: Invoke-ClaudeDoctorInteractiveSafe (CCDI_TEST_MODE=1 auto-protect)"
    $t2d = Invoke-ClaudeDoctorInteractiveSafe -TimeoutSec 5
    if ($t2d.Error -ne "skipped_test_safe") {
        throw "Invoke-ClaudeDoctorInteractiveSafe with CCDI_TEST_MODE=1 should auto-skip, got: $($t2d.Error)"
    }
    Write-Host "[check]     Auto-protected by CCDI_TEST_MODE=1"

    # Test 2e: Invoke-ClaudeDoctorInteractiveSafe return shape
    Write-Host "[check]   Test 2e: Invoke-ClaudeDoctorInteractiveSafe return shape"
    $requiredInteractiveKeys = @("Success", "TimedOut", "ExitCode", "Error", "Command", "DurationMs")
    foreach ($key in $requiredInteractiveKeys) {
        if ($t2c.Keys -notcontains $key) {
            throw "Invoke-ClaudeDoctorInteractiveSafe missing field: $key"
        }
    }
    Write-Host "[check]     All required fields present"

    # Test 2f: Clear-StaleClaudeDoctorProcesses returns expected shape
    Write-Host "[check]   Test 2f: Clear-StaleClaudeDoctorProcesses return shape"
    $t2f = Clear-StaleClaudeDoctorProcesses
    if ($t2f.Keys -notcontains "KilledCount") {
        throw "Clear-StaleClaudeDoctorProcesses missing KilledCount field"
    }
    if ($t2f.Keys -notcontains "Errors") {
        throw "Clear-StaleClaudeDoctorProcesses missing Errors field"
    }
    Write-Host "[check]     KilledCount=$($t2f.KilledCount), Errors=$($t2f.Errors.Count)"

    # ----------------------------------------------------------
    # Test 3/4/8: optional network checks
    # ----------------------------------------------------------
    if ($Network) {
        Write-Host "[check]   Network: example.com"
        $t3 = Test-HttpEndpointReachable -Url "https://example.com" -TimeoutSec 10
        Write-NetworkCheckResult -Name "example.com" -Reachable $t3.Reachable -Detail "StatusCode=$($t3.StatusCode); Error=$($t3.Error)"

        Write-Host "[check]   Network: Claude official install channel"
        $t4 = Test-ClaudeOfficialInstallNetwork
        $requiredKeys = @("Reachable", "InstallScriptOk", "DownloadsOk", "Details")
        foreach ($key in $requiredKeys) {
            if ($t4.Keys -notcontains $key) {
                throw "Test-ClaudeOfficialInstallNetwork missing field: $key"
            }
        }
        Write-NetworkCheckResult -Name "Claude official install channel" -Reachable $t4.Reachable -Detail "InstallScriptOk=$($t4.InstallScriptOk); DownloadsOk=$($t4.DownloadsOk); Details=$($t4.Details)"
    }
    else {
        Write-Host "[check]   Network checks skipped (pass -Network to enable; add -StrictNetwork to fail on network errors)"
    }

    # ----------------------------------------------------------
    # Test 5: Install-ClaudeCodeAuto -TestSafe (claude absent → skip)
    # ----------------------------------------------------------
    Write-Host "[check]   Test 5: Install-ClaudeCodeAuto -TestSafe (claude absent)"
    $t5 = Install-ClaudeCodeAuto -TestSafe
    if ($t5.Status -notmatch "^skipped_test_safe_") {
        throw "Expected skipped_test_safe_* in TestSafe mode, got: $($t5.Status)"
    }
    if ($t5.Method -notin @("none", "existing")) {
        throw "Expected Method=none, got: $($t5.Method)"
    }
    Write-Host "[check]     Status=$($t5.Status) (correct)"

    Write-Host "[check]   Test 5b: Install-ClaudeCodeAuto (no TestSafe param, but CCDI_TEST_MODE=1)"
    $t5b = Install-ClaudeCodeAuto
    if ($t5b.Status -notmatch "^skipped_test_safe_") {
        throw "Install-ClaudeCodeAuto with CCDI_TEST_MODE=1 should auto-skip, got: $($t5b.Status)"
    }
    Write-Host "[check]     Auto-protected by CCDI_TEST_MODE=1, Status=$($t5b.Status)"

    # ----------------------------------------------------------
    # Test 6: Install-ClaudeCodeNative -TestSafe skips real install
    # ----------------------------------------------------------
    Write-Host "[check]   Test 6: Install-ClaudeCodeNative -TestSafe does not execute"
    $t6 = Install-ClaudeCodeNative -TestSafe
    if ($t6.Success) {
        throw "Install-ClaudeCodeNative -TestSafe should return Success=false"
    }
    if ($t6.Status -ne "skipped_test_safe") {
        throw "Install-ClaudeCodeNative -TestSafe should return Status=skipped_test_safe, got: $($t6.Status)"
    }
    Write-Host "[check]     Success=$($t6.Success) (correctly skipped)"

    # Test 6b: Install-ClaudeCodeNative without -TestSafe BUT CCDI_TEST_MODE=1
    Write-Host "[check]   Test 6b: Install-ClaudeCodeNative (no TestSafe, CCDI_TEST_MODE=1 auto-protect)"
    $t6b = Install-ClaudeCodeNative
    if ($t6b.Success) {
        throw "Install-ClaudeCodeNative with CCDI_TEST_MODE=1 should auto-skip, got Success=true"
    }
    if ($t6b.Status -ne "skipped_test_safe") {
        throw "Install-ClaudeCodeNative with CCDI_TEST_MODE=1 should return Status=skipped_test_safe, got: $($t6b.Status)"
    }
    Write-Host "[check]     Auto-protected by CCDI_TEST_MODE=1, Success=$($t6b.Success)"

    # ----------------------------------------------------------
    # Test 7: Install-ClaudeCodeNpmMirror -TestSafe skips real install
    # ----------------------------------------------------------
    Write-Host "[check]   Test 7: Install-ClaudeCodeNpmMirror -TestSafe does not execute"
    $t7 = Install-ClaudeCodeNpmMirror -TestSafe
    if ($t7.Success) {
        throw "Install-ClaudeCodeNpmMirror -TestSafe should return Success=false"
    }
    if ($t7.Status -ne "skipped_test_safe") {
        throw "Install-ClaudeCodeNpmMirror -TestSafe should return Status=skipped_test_safe, got: $($t7.Status)"
    }
    Write-Host "[check]     Success=$($t7.Success) (correctly skipped)"

    # Test 7b: Install-ClaudeCodeNpmMirror without -TestSafe BUT CCDI_TEST_MODE=1
    Write-Host "[check]   Test 7b: Install-ClaudeCodeNpmMirror (no TestSafe, CCDI_TEST_MODE=1 auto-protect)"
    $t7b = Install-ClaudeCodeNpmMirror
    if ($t7b.Success) {
        throw "Install-ClaudeCodeNpmMirror with CCDI_TEST_MODE=1 should auto-skip, got Success=true"
    }
    if ($t7b.Status -ne "skipped_test_safe") {
        throw "Install-ClaudeCodeNpmMirror with CCDI_TEST_MODE=1 should return Status=skipped_test_safe, got: $($t7b.Status)"
    }
    Write-Host "[check]     Auto-protected by CCDI_TEST_MODE=1, Success=$($t7b.Success)"

    if ($Network) {
        Write-Host "[check]   Network: npmmirror"
        $t8 = Test-NpmMirrorClaudeCodeNetwork
        $mirrorKeys = @("Reachable", "NpmAvailable", "NodeOk", "Error")
        foreach ($key in $mirrorKeys) {
            if ($t8.Keys -notcontains $key) {
                throw "Test-NpmMirrorClaudeCodeNetwork missing field: $key"
            }
        }
        Write-NetworkCheckResult -Name "npmmirror" -Reachable $t8.Reachable -Detail "NodeOk=$($t8.NodeOk); NpmAvailable=$($t8.NpmAvailable); Error=$($t8.Error)"
    }

    # ----------------------------------------------------------
    # Test 9: Install-ClaudeCodeAuto status values sanity
    # ----------------------------------------------------------
    Write-Host "[check]   Test 9: Install-ClaudeCodeAuto return shape"
    $autoKeys = @("Success", "Method", "Status", "Version", "WasAlreadyInstalled")
    foreach ($key in $autoKeys) {
        if ($t5.Keys -notcontains $key) {
            throw "Install-ClaudeCodeAuto missing field: $key"
        }
    }

    # All valid Method values
    $validMethods = @("existing", "official_native", "npm_npmmirror", "none",
        "node-via-winget")
    $validStatuses = @("skipped_existing", "skipped_test_safe_existing", "skipped_test_safe_missing",
        "skipped_test_safe_broken", "installed", "installed_needs_restart",
        "node_installed_needs_restart", "failed_missing_node_or_npm",
        "failed_npmmirror_unreachable", "failed_official_and_mirror")
    Write-Host "[check]     Valid Methods: $($validMethods -join ', ')"
    Write-Host "[check]     Valid Statuses: $($validStatuses -join ', ')"

    # Start-Here.ps1 must continue in TestSafe when claude is missing/broken.
    $startHereText = Get-Content (Join-Path $RootDir "Start-Here.ps1") -Raw
    if ($startHereText -notmatch '\$script:TestSafeMode\s+-and\s+\$installResult\.Status\s+-match\s+"\^skipped_test_safe_"') {
        throw "Start-Here.ps1 must treat skipped_test_safe_* as a TestSafe continuation state"
    }

    Write-Host "[check]   All safety and structure checks passed"
}
finally {
    # 恢复环境变量
    $env:CCDI_TEST_MODE = $origTestMode
    if ($origUserProfile) { $env:CCDI_TEST_USERPROFILE = $origUserProfile } else { Remove-Item Env:\CCDI_TEST_USERPROFILE -ErrorAction SilentlyContinue }
    if ($origTestDesktop) { $env:CCDI_TEST_DESKTOP = $origTestDesktop } else { Remove-Item Env:\CCDI_TEST_DESKTOP -ErrorAction SilentlyContinue }
    if ($origApiKey) { $env:CCDI_API_KEY = $origApiKey } else { Remove-Item Env:\CCDI_API_KEY -ErrorAction SilentlyContinue }

    # 清理测试目录
    if (Test-Path $testUserProfile) { Remove-Item $testUserProfile -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $testDesktop) { Remove-Item $testDesktop -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "[check] OK"
