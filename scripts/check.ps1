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
    "Invoke-ClaudeDoctor",
    "Parse-ClaudeDoctorOutput",
    "Clear-StaleClaudeDoctorProcesses",
    "Remove-AnsiEscape",
    "Remove-ControlChars",
    "Test-Mojibake",
    "Repair-OrSuppressMojibake",
    "Normalize-ExternalCommandOutput",
    "Convert-ToSafeReportText",
    "Test-WslClaudeComprehensive",
    "Get-WslVersionClean"
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
if ($claudeInstallText -notmatch 'CleanedOutput\s*=\s*""') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must include CleanedOutput field in result"
}

# 2. doctor.ps1 calls Invoke-ClaudeDoctor (new entry point), not Invoke-CommandSafe for claude doctor
if ($doctorText -notmatch 'Invoke-ClaudeDoctor\b') {
    throw "doctor.ps1 must use Invoke-ClaudeDoctor for claude doctor diagnostics"
}
if ($doctorText -match 'Invoke-CommandSafe\s+-Command\s+"claude"\s+-Arguments\s+@\("doctor"\)') {
    throw "doctor.ps1 must NOT use Invoke-CommandSafe to run claude doctor"
}

# 3. doctor.ps1 handles TimedOut separately via Invoke-ClaudeDoctor result
if ($doctorText -notmatch 'claudeDoctor\.TimedOut') {
    throw "doctor.ps1 must check claudeDoctor.TimedOut for timeout-specific messaging"
}
if ($doctorText -notmatch '官方 doctor 进入交互式流程') {
    throw "doctor.ps1 must handle interactive prompt timeout specifically"
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

# 19. doctor.ps1 must handle watchdog_unavailable_skipped from Invoke-ClaudeDoctor result
if ($doctorText -notmatch 'DoctorAvailable' -and $doctorText -notmatch 'watchdog_unavailable_skipped') {
    throw "doctor.ps1 must handle watchdog_skipped state via DoctorAvailable or watchdog_unavailable_skipped"
}
if ($doctorText -notmatch '超时保护不可用.*Start-Job 被禁用') {
    throw "doctor.ps1 must clearly explain that Start-Job disabled caused the skip"
}

Write-Host "[check] Claude doctor interactive invocation OK"

Write-Host "[check] Text cleaning and report safety functions"
$claudeInstallText = Get-Content -Path (Join-Path $RootDir "lib\claude-install.ps1") -Raw -Encoding UTF8

# 35. Remove-AnsiEscape must handle common ANSI sequences (universal CSI pattern)
if ($commonText -notmatch 'function Remove-AnsiEscape') {
    throw "Remove-AnsiEscape function not found in lib/common.ps1"
}
# Verify universal CSI pattern: ESC[ params... intermediate... final byte
if ($commonText -notmatch '\[0-\?\]\*\[ -\/\]\*\[@-~\]') {
    throw "Remove-AnsiEscape must use universal CSI pattern \x1B[[0-?]*[ -/]*[@-~]"
}

# 36. Test-Mojibake must detect known garbled characters (compound, not false-positive singles)
if ($commonText -notmatch 'function Test-Mojibake') {
    throw "Test-Mojibake function not found in lib/common.ps1"
}
# 单字符乱码特征必须存在（但不包含 斤/拷）
$mojibakeChars = @('鈹', '鉁', '鈥', '銆', '鈩')
$foundChars = $true
foreach ($mc in $mojibakeChars) {
    if ($commonText -notmatch [regex]::Escape($mc)) {
        $foundChars = $false
        break
    }
}
if (-not $foundChars) {
    throw "Test-Mojibake must check for known mojibake characters (鈹/鉁/鈥)"
}
# 组合模式 "锟斤拷" 必须存在（不会误伤正常中文 "公斤" "拷贝"）
if ($commonText -notmatch '锟斤拷') {
    throw "Test-Mojibake must check for compound pattern 锟斤拷 (not single 斤/拷)"
}
# 单个 "斤" 或 "拷" 不应出现在单字符列表中
if ($commonText -match "'斤'" -or $commonText -match "'拷'") {
    throw "Test-Mojibake must NOT treat single 斤/拷 as mojibake (false positive on 公斤/拷贝)"
}

# 37. Normalize-ExternalCommandOutput chains cleaning functions
if ($commonText -notmatch 'function Normalize-ExternalCommandOutput') {
    throw "Normalize-ExternalCommandOutput function not found in lib/common.ps1"
}

# 38. Convert-ToSafeReportText must exist and filter internal fields
if ($commonText -notmatch 'function Convert-ToSafeReportText') {
    throw "Convert-ToSafeReportText function not found in lib/common.ps1"
}
# Check for filtering of critical internal fields
$filterChecks = @('GrowthBook', 'OAuth', 'tengu_ccr_bridge', 'organization')
$allFiltered = $true
foreach ($fc in $filterChecks) {
    if ($commonText -notmatch [regex]::Escape($fc)) {
        $allFiltered = $false
        break
    }
}
if (-not $allFiltered) {
    throw "Convert-ToSafeReportText must filter internal fields (GrowthBook/OAuth/feature flags)"
}

# 39. Parse-ClaudeDoctorOutput must exist in claude-install.ps1
if ($claudeInstallText -notmatch 'function Parse-ClaudeDoctorOutput') {
    throw "Parse-ClaudeDoctorOutput function not found in lib/claude-install.ps1"
}
if ($claudeInstallText -notmatch 'GrowthBook') {
    throw "Parse-ClaudeDoctorOutput must filter GrowthBook internal fields"
}

# 40. Invoke-ClaudeDoctor must exist and handle graded timeout
if ($claudeInstallText -notmatch 'function Invoke-ClaudeDoctor\b') {
    throw "Invoke-ClaudeDoctor function not found in lib/claude-install.ps1"
}
# 40b. Invoke-ClaudeDoctor must include Severity field in result
if ($claudeInstallText -notmatch 'Severity\s*=\s*"') {
    throw "Invoke-ClaudeDoctor must include Severity field in its result hashtable"
}

# 40c. doctor.ps1 must use Severity-based switch (not Success-first if/else chain that can mistake TimedOut for OK)
if ($doctorText -notmatch 'claudeDoctor\.Severity') {
    throw "doctor.ps1 must use Severity field for claude doctor status (not Success-first checking)"
}
# 40d. TimedOut+HasCoreFields must NOT be handled before Severity switch (prevent OK misclassification)
if ($doctorText -notmatch 'switch\s*\(\$claudeDoctor\.Severity\)') {
    throw "doctor.ps1 must switch on Severity to prevent TimedOut+HasCoreFields from being classified as OK"
}

# 41. Invoke-ClaudeDoctorInteractiveSafe must set NO_COLOR/CI/TERM env vars
if ($claudeInstallText -notmatch 'NO_COLOR.*=.*"1"') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must set NO_COLOR=1"
}
if ($claudeInstallText -notmatch 'TERM.*=.*"dumb"') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must set TERM=dumb"
}

# 42. Test-WslClaudeComprehensive must exist
$envCheckText = Get-Content -Path (Join-Path $RootDir "lib\env-check.ps1") -Raw -Encoding UTF8
if ($envCheckText -notmatch 'function Test-WslClaudeComprehensive') {
    throw "Test-WslClaudeComprehensive function not found in lib/env-check.ps1"
}

# 43. Get-WslVersionClean must use regex extraction
if ($envCheckText -notmatch 'function Get-WslVersionClean') {
    throw "Get-WslVersionClean function not found in lib/env-check.ps1"
}
if ($envCheckText -notmatch '\\d\+\\\.\\d\+\\\.\\d\+') {
    throw "Get-WslVersionClean must use regex \d+\.\d+\.\d+ to extract version"
}

# 44. doctor.ps1 report must use Convert-ToSafeReportText
$doctorText = Get-Content -Path (Join-Path $RootDir "doctor.ps1") -Raw -Encoding UTF8
if ($doctorText -notmatch 'Convert-ToSafeReportText') {
    throw "doctor.ps1 must use Convert-ToSafeReportText for report sanitization"
}

# 45. doctor.ps1 must have encoding initialization
if ($doctorText -notmatch 'Console\]::InputEncoding.*UTF8Encoding' -or
    $doctorText -notmatch 'Console\]::OutputEncoding.*UTF8Encoding') {
    throw "doctor.ps1 must initialize console encoding to UTF-8"
}

# 46. Invoke-ClaudeDoctorInteractiveSafe must send newlines to stdin
if ($claudeInstallText -notmatch 'StandardInput' -or $claudeInstallText -notmatch 'WriteLine') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must write newlines to stdin to prevent pagination"
}

# 47. Test-UbuntuInWsl must return Name field
if ($envCheckText -notmatch 'Name\s*=\s*\$distro\.Name' -and $envCheckText -notmatch 'Name\s*=\s*\$distro\.Name') {
    # Fallback: check that Name field exists in result hashtable
    if ($envCheckText -notmatch 'Name\s*=\s*\$null' -and $envCheckText -notmatch '"Name"') {
        Write-Host "  WARN: Test-UbuntuInWsl may not return Name field"
    }
}
if ($envCheckText -notmatch 'Name\s*=\s*\$') {
    throw "Test-UbuntuInWsl must include Name field in its return hashtable"
}

# 48. Check-WSL must NOT hardcode -d "Ubuntu" in startup check
if ($doctorText -match '-d",\s*"Ubuntu",\s*"bash"' -or $doctorText -match '-d", "Ubuntu", "bash"') {
    throw "Check-WSL must not hardcode 'Ubuntu' in wsl -d argument; use ubuntuDistroName variable"
}
# Must use ubuntuDistroName variable for -d argument
if ($doctorText -notmatch 'ubuntuDistroName') {
    throw "Check-WSL must use ubuntuDistroName variable for WSL distro detection"
}

# 49. WSL settings.json check must use -d with distro name
# doctor.ps1 must contain both -d $ubuntuDistroName and settings.json near the WSL config check
$doctorText = Get-Content -Path (Join-Path $RootDir "doctor.ps1") -Raw -Encoding UTF8
if ($doctorText -notmatch '\-d.*\$ubuntuDistroName' -and $doctorText -notmatch '\$ubuntuDistroName.*\-d') {
    throw "WSL settings.json detection must use -d `$ubuntuDistroName somewhere in Check-WSL"
}
# The wsl settings check area must reference settings.json
if ($doctorText -notmatch 'settings\.json.*EXISTS.*NOT_FOUND') {
    throw "WSL settings.json detection must still check for settings.json"
}

# 50. Test-WslClaudeComprehensive base64 must check availability BEFORE piping to bash
if ($envCheckText -notmatch 'command\s+-v\s+base64') {
    throw "Test-WslClaudeComprehensive must check 'command -v base64' before piping to bash"
}
if ($envCheckText -notmatch 'base64\s+-d' -or $envCheckText -notmatch 'base64\s+--decode') {
    throw "Test-WslClaudeComprehensive base64 must support both 'base64 -d' and 'base64 --decode'"
}
if ($envCheckText -notmatch 'CCDI_BASE64_MISSING') {
    throw "Test-WslClaudeComprehensive must handle missing base64 command (CCDI_BASE64_MISSING)"
}
if ($envCheckText -notmatch 'CCDI_BASE64_DECODE_FAILED') {
    throw "Test-WslClaudeComprehensive must handle base64 decode failure (CCDI_BASE64_DECODE_FAILED)"
}
# CCDI_BASE64_MISSING must NOT be piped to bash (must exit before pipe)
if ($envCheckText -match 'CCDI_BASE64_MISSING.*\|.*bash') {
    throw "CCDI_BASE64_MISSING must NOT be piped to bash; exit before decode"
}
# Must use printf instead of echo for base64 piping
if ($envCheckText -notmatch "printf.*%s.*encodedScript") {
    throw "Test-WslClaudeComprehensive must use printf (not echo) for base64 piping"
}
# decoded must be double-quoted when piped to bash (prevent word splitting)
# The safe form in raw file content is: `"`$decoded`" | bash
# This check ensures the printf-to-bash line wraps $decoded in backtick-quote pairs
$envCheckText = Get-Content -Path (Join-Path $RootDir "lib\env-check.ps1") -Raw -Encoding UTF8
if ($envCheckText -notmatch 'printf.*decoded.*\|.*bash') {
    throw "decoded must be piped to bash via printf"
}
# Raw file must contain backtick-quote around decoded before pipe: `"`$decoded`" |
# Regex: ` matches literal backtick, " matches literal quote, \$ matches literal $
if ($envCheckText -notmatch '`"\`\$decoded`"\s*\|\s*bash') {
    throw "decoded variable must be double-quoted when piped to bash: use printf '%s' `"`$decoded`" | bash"
}

# 51. Check-WSL must pass distro name to Test-WslClaudeComprehensive
if ($doctorText -notmatch 'Test-WslClaudeComprehensive\s+-DistroName') {
    throw "Check-WSL must pass -DistroName to Test-WslClaudeComprehensive"
}

Write-Host "[check] Text cleaning and report safety functions OK"
Write-Host "[check] WSL distro name and base64 compatibility OK"

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

# 30. Invoke-ClaudeDoctorInteractiveSafe uses Start-Process with ProcessStartInfo (not direct invocation)
if ($claudeInstallText -notmatch 'System\.Diagnostics\.ProcessStartInfo') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must use ProcessStartInfo for isolated doctor execution"
}
if ($claudeInstallText -notmatch 'RedirectStandardOutput\s*=\s*\$true') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must redirect stdout"
}
if ($claudeInstallText -notmatch 'RedirectStandardInput\s*=\s*\$true') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must redirect stdin (for Enter prevention)"
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

Write-Host "[check] Legacy install.ps1 entry point guardrails"
$installPs1Text = Get-Content -Path (Join-Path $RootDir "install.ps1") -Raw -Encoding UTF8

# 1. Must contain deprecation notice
if ($installPs1Text -notmatch '旧入口' -and $installPs1Text -notmatch '推荐入口是 Start-Here\.ps1') {
    throw "install.ps1 must contain deprecation notice ('旧入口' or '推荐入口是 Start-Here.ps1')"
}

# 2. Must reference Start-Here.ps1
if ($installPs1Text -notmatch 'Start-Here\.ps1') {
    throw "install.ps1 must reference Start-Here.ps1"
}

# 3. Must NOT contain old Show-Menu function
if ($installPs1Text -match 'function Show-Menu') {
    throw "install.ps1 must NOT contain Show-Menu function"
}

# 4. Must NOT contain Step-InstallVSCodeExtension
if ($installPs1Text -match 'Step-InstallVSCodeExtension') {
    throw "install.ps1 must NOT contain Step-InstallVSCodeExtension"
}

# 5. Must NOT contain code --install-extension in any form
if ($installPs1Text -match 'code[\s\S]{0,100}--install-extension') {
    throw "install.ps1 must NOT contain code --install-extension in any form"
}

# 6. Must NOT contain Invoke-CommandSafe calling code (old VS Code extension pattern)
if ($installPs1Text -match 'Invoke-CommandSafe[\s\S]{0,200}"code"') {
    throw "install.ps1 must NOT contain Invoke-CommandSafe calling code"
}

# 7. Must NOT be an independent install entry (no legacy step functions)
$legacyStepFunctions = @(
    'function Step-InstallClaudeCode',
    'function Step-ConfigureDeepSeek',
    'function Step-CheckEnvironment',
    'function Show-FinalSummary'
)
foreach ($func in $legacyStepFunctions) {
    if ($installPs1Text -match [regex]::Escape($func)) {
        throw "install.ps1 must NOT contain legacy step function: $func"
    }
}

# 8. Must NOT contain independent deepseek config write (Write-DeepSeekConfig called directly)
if ($installPs1Text -match 'Write-DeepSeekConfig\s+-ApiKey') {
    throw "install.ps1 must NOT independently write DeepSeek config"
}

# 9. Should be a lightweight shim (<= 120 lines)
$installLineCount = ($installPs1Text -split "`n").Count
if ($installLineCount -gt 120) {
    throw "install.ps1 should be a lightweight shim (<= 120 lines), actually $installLineCount lines"
}

# 10. Must NOT contain exit $LASTEXITCODE (unreliable for .ps1 exit status)
if ($installPs1Text -match 'exit\s+\$LASTEXITCODE') {
    throw "install.ps1 must NOT use exit `$LASTEXITCODE; use Invoke-CcdiScriptAndExit instead"
}

# 11. Must contain Invoke-CcdiScriptAndExit safe forwarding function
if ($installPs1Text -notmatch 'function Invoke-CcdiScriptAndExit') {
    throw "install.ps1 must define Invoke-CcdiScriptAndExit safe forwarding function"
}

# 12. All three forwarding branches must use Invoke-CcdiScriptAndExit
if ($installPs1Text -notmatch 'Invoke-CcdiScriptAndExit\s+-ScriptPath\s+\$doctorPath') {
    throw "install.ps1 Doctor branch must use Invoke-CcdiScriptAndExit"
}
if ($installPs1Text -notmatch 'Invoke-CcdiScriptAndExit\s+-ScriptPath\s+\$configPath') {
    throw "install.ps1 ConfigureOnly branch must use Invoke-CcdiScriptAndExit"
}
if ($installPs1Text -notmatch 'Invoke-CcdiScriptAndExit\s+-ScriptPath\s+\$startHerePath') {
    throw "install.ps1 Start-Here forwarding must use Invoke-CcdiScriptAndExit"
}

# 13. Doctor mode forwardMessage must NOT say "一键安装流程" (inaccurate for diagnostic mode)
if ($installPs1Text -notmatch '"Doctor"\s+\{\s*"正在切换到新版诊断入口') {
    throw "install.ps1 Doctor mode must use diagnostic-specific forwarding message (not '一键安装流程')"
}

# 14. ConfigureOnly mode forwardMessage must NOT say "一键安装流程" (inaccurate for config-only mode)
if ($installPs1Text -notmatch '"ConfigureOnly"\s+\{\s*"正在切换到 DeepSeek 单独配置入口') {
    throw "install.ps1 ConfigureOnly mode must use config-specific forwarding message (not '一键安装流程')"
}

Write-Host "[check] Legacy install.ps1 entry point guardrails OK"

# ============================================================
# UX 文案检查（v1.3.2 第二轮优化）
# ============================================================
Write-Host "[check] UX text checks for API key onboarding and wait-state messaging"

$startHereText = Get-Content -Path (Join-Path $RootDir "Start-Here.ps1") -Raw -Encoding UTF8
$configureText = Get-Content -Path (Join-Path $RootDir "configure-deepseek.ps1") -Raw -Encoding UTF8

# 1. Step-GetApiKey 菜单文案
$menuTexts = @(
    "我已复制 Key，开始粘贴",
    "重新打开 DeepSeek API Key 页面",
    "暂时跳过，稍后配置",
    "查看获取 Key 的简明步骤"
)
foreach ($mt in $menuTexts) {
    if ($startHereText -notmatch [regex]::Escape($mt)) {
        throw "Step-GetApiKey missing menu text: $mt"
    }
}

# 2. Step-TestApi 等待提示
$waitTexts = @(
    "最长等待 30 秒",
    "配置仍会保留"
)
foreach ($wt in $waitTexts) {
    if ($startHereText -notmatch [regex]::Escape($wt)) {
        throw "Step-TestApi missing wait prompt: $wt"
    }
}

# 3. Start-LazyInstall Step 2 之后不得只有无上下文的 Pause-ForUser -Force
# 必须包含 "Claude Code 安装验证已通过" 等上下文
if ($startHereText -notmatch "Claude Code 安装验证已通过") {
    throw "Start-LazyInstall must show context message after Step 2 install success"
}
if ($startHereText -notmatch "下一步将配置 DeepSeek API Key") {
    throw "Start-LazyInstall must explain next step (DeepSeek API Key config) after Step 2"
}
if ($startHereText -notmatch "检测到 Claude Code 已安装，继续配置 DeepSeek") {
    throw "Start-LazyInstall must show existing-install message when Claude is already installed"
}

# 4. configure-deepseek.ps1 API 测试最长等待提示
if ($configureText -notmatch [regex]::Escape("最长等待 30 秒")) {
    throw "configure-deepseek.ps1 must prompt '最长等待 30 秒' before API test"
}
if ($configureText -notmatch [regex]::Escape("如果失败，配置仍会保留")) {
    throw "configure-deepseek.ps1 must show '配置仍会保留' on API test failure path"
}

# 5. configure-deepseek.ps1 key input prompts
if ($configureText -notmatch "输入时不会显示字符，这是正常的安全保护") {
    throw "configure-deepseek.ps1 must show security notice before key input"
}
if ($configureText -notmatch "下一步会显示脱敏后的 Key，可选择 R 重新粘贴") {
    throw "configure-deepseek.ps1 must show re-paste hint before key input"
}

# 6. SkipApiTest / TestSafe / NonInteractive 不受影响
# Step-GetApiKey NonInteractive 路径必须存在（不做菜单）
if ($startHereText -notmatch 'if\s*\(\$NonInteractive\)\s*\{[\s\S]{0,300}Get-ApiKeyFromEnvironment') {
    throw "Step-GetApiKey NonInteractive path must still use Get-ApiKeyFromEnvironment"
}
# Step-TestApi SkipApiTest 路径必须存在
if ($startHereText -notmatch '\$script:EffectiveSkipApiTest') {
    throw "Step-TestApi must still check EffectiveSkipApiTest"
}

Write-Host "[check] UX text checks OK"

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
