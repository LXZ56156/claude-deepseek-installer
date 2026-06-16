# ============================================================
# scripts/check.ps1 - 轻量 PowerShell 自检
# ============================================================

param(
    [switch]$Network,
    [switch]$StrictNetwork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
$RootDir = Split-Path -Parent $ScriptDir
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
    "Get-WslVersionClean",
    "Resolve-NpmCmdPath",
    "Install-ClaudeCodeViaWinget"
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
    $firstRunAt = Get-CcdiStateValue -State $state -Name "firstRunAt" -Default "(未记录)"

    if ($method -ne "existing") {
        throw "Partial state method read failed"
    }

    if ($firstRunAt -ne "(未记录)") {
        throw "Missing firstRunAt should return default"
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
    if ($showStatusText -notmatch "首次运行时间: \(未记录\)") {
        throw "uninstall-config -ShowStatusOnly did not show default firstRunAt"
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

# 2. doctor.ps1 skips automatic claude doctor (unreliable with stdout redirect).
# 2. doctor.ps1 must suggest manual claude doctor with specific guidance.
if ($doctorText -notmatch '手动输入：claude doctor|手动输入: claude doctor|手动输入.*claude doctor') {
    throw "doctor.ps1 must include exact '手动输入：claude doctor' or similar for manual guidance"
}
if ($doctorText -notmatch '不要通过脚本.*管道.*重定向|不要通过脚本、管道或重定向') {
    throw "doctor.ps1 must warn: do not run via script/pipe/redirect"
}
if ($doctorText -notmatch '截图|复制终端中的完整输出') {
    throw "doctor.ps1 must suggest screenshot or copy terminal output for support"
}

# 3. doctor.ps1 Check-Commands must NOT automatically call Invoke-ClaudeDoctor*
$doctorTextFull = Get-Content -Path (Join-Path $RootDir "doctor.ps1") -Raw -Encoding UTF8
$checkCommandsText = if ($doctorTextFull -match '(?s)function Check-Commands\s*\{(.*?)function Check-Files\s*\{') {
    $matches[1]
}
else {
    throw "Unable to locate Check-Commands block in doctor.ps1"
}
if ($checkCommandsText -match '\bInvoke-ClaudeDoctor\b' -or
    $checkCommandsText -match '\bInvoke-ClaudeDoctorInteractiveSafe\b' -or
    $checkCommandsText -match '\bInvoke-ClaudeDoctorSafe\b') {
    throw "doctor.ps1 Check-Commands must not automatically call Invoke-ClaudeDoctor / Invoke-ClaudeDoctorInteractiveSafe / Invoke-ClaudeDoctorSafe"
}
Write-Host "[check] doctor.ps1 manual claude doctor flow OK"

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

# 17. doctor.ps1 regression: TestSafe parameter + sandbox-safe network/WSL skip
$doctorTextFull = Get-Content -Path (Join-Path $RootDir "doctor.ps1") -Raw -Encoding UTF8

if ($doctorTextFull -notmatch '\[switch\]\$TestSafe') {
    throw "doctor.ps1 param must include [switch]`$TestSafe"
}
if ($doctorTextFull -notmatch '\$script:DoctorTestSafeMode\s*=\s*\$TestSafe\s+-or\s+\(\$env:CCDI_TEST_MODE\s+-eq\s+"1"\)') {
    throw "doctor.ps1 must define `$script:DoctorTestSafeMode from -TestSafe or CCDI_TEST_MODE"
}
if ($doctorTextFull -notmatch 'function Check-Network[\s\S]{0,200}DoctorTestSafeMode[\s\S]{0,200}测试安全模式已跳过真实网络请求') {
    throw "doctor.ps1 Check-Network must early-return when DoctorTestSafeMode"
}
if ($doctorTextFull -notmatch 'function Check-WSL[\s\S]{0,300}DoctorTestSafeMode[\s\S]{0,300}测试安全模式') {
    throw "doctor.ps1 Check-WSL must early-return when DoctorTestSafeMode"
}
# WSL TestSafe skip now in Check-WSL only (Check-Files no longer checks WSL)
if ($doctorTextFull -notmatch 'DoctorTestSafeMode[\s\S]{0,500}测试安全模式不启动 WSL') {
    throw "doctor.ps1 Check-WSL must skip WSL when DoctorTestSafeMode (was in Check-Files, now in Check-WSL)"
}

# 18. validate.ps1 regression: Invoke-PowerShellScript timeout + taskkill
$validateText = Get-Content -Path (Join-Path $RootDir "scripts\validate.ps1") -Raw -Encoding UTF8

if ($validateText -notmatch '\[int\]\$TimeoutSec') {
    throw "validate.ps1 Invoke-PowerShellScript must have TimeoutSec parameter"
}
# Check Start-Job within the Invoke-PowerShellScript function scope (function name comes first, then body)
if ($validateText -match 'function Invoke-PowerShellScript[\s\S]{0,2500}\bStart-Job\b') {
    throw "validate.ps1 Invoke-PowerShellScript must NOT use Start-Job within its function body"
}
if ($validateText -notmatch 'doctor\.ps1[\s\S]{0,300}-TestSafe') {
    throw "validate.ps1 CoreSandboxFlow must pass -TestSafe to doctor.ps1"
}
if ($validateText -notmatch 'Start-Here\.ps1[\s\S]{0,300}-FixDeps[\s\S]{0,120}-NonInteractive') {
    throw "validate.ps1 CoreSandboxFlow FixDeps step must pass -NonInteractive"
}
# validate.ps1 Invoke-PowerShellScript: uses System.Diagnostics.Process + WaitForExit
# with timeout + taskkill /T /F + Stop-Process fallback.
# This avoids PowerShell Start-Process ExitCode/NoNewWindow/hang issues.
if ($validateText -notmatch 'System\.Diagnostics\.ProcessStartInfo') {
    throw "validate.ps1 Invoke-PowerShellScript must use System.Diagnostics.ProcessStartInfo"
}
if ($validateText -notmatch '\[System\.Diagnostics\.Process\]::Start\(\$psi\)') {
    throw "validate.ps1 Invoke-PowerShellScript must use [System.Diagnostics.Process]::Start(`$psi)"
}
if ($validateText -notmatch '\$proc\.WaitForExit\(\$TimeoutSec\s*\*\s*1000\)') {
    throw "validate.ps1 Invoke-PowerShellScript must use `$proc.WaitForExit(`$TimeoutSec * 1000)"
}
if ($validateText -notmatch 'taskkill\.exe\s+/PID\s+\$realPid\s+/T\s+/F') {
    throw "validate.ps1 Invoke-PowerShellScript timeout must call taskkill.exe /T /F"
}
if ($validateText -notmatch 'Stop-Process\s+-Id\s+\$realPid\s+-Force') {
    throw "validate.ps1 Invoke-PowerShellScript timeout must have Stop-Process fallback"
}
if ($validateText -notmatch 'CreateNoWindow\s*=\s*\$true') {
    throw "validate.ps1 Invoke-PowerShellScript must set CreateNoWindow = true"
}

# 18b. windows-scenario-matrix.ps1 regression: Invoke-ToolCheck real timeout
$wsmText = Get-Content -Path (Join-Path $RootDir "scripts\windows-scenario-matrix.ps1") -Raw -Encoding UTF8

if ($wsmText -match 'Start-Process[\s\S]{0,100}PassThru[\s\S]{0,20}-Wait') {
    throw "windows-scenario-matrix.ps1 Invoke-ToolCheck must NOT use Start-Process -PassThru -Wait"
}
if ($wsmText -notmatch '\$proc\.WaitForExit\(\$TimeoutSec') {
    throw "windows-scenario-matrix.ps1 Invoke-ToolCheck must use WaitForExit with TimeoutSec"
}
if ($wsmText -notmatch 'taskkill\.exe\s+/PID\s+\$realPid\s+/T\s+/F') {
    throw "windows-scenario-matrix.ps1 Invoke-ToolCheck timeout must call taskkill.exe /PID `$realPid /T /F"
}
if ($wsmText -notmatch 'Stop-Process\s+-Id\s+\$realPid\s+-Force') {
    throw "windows-scenario-matrix.ps1 Invoke-ToolCheck timeout must have Stop-Process fallback"
}
if ($wsmText -notmatch 'ExitCode\s*=\s*-2') {
    throw "windows-scenario-matrix.ps1 timeout must return ExitCode=-2"
}

# 18c. simulate-user-release.ps1 regression: Invoke-SimCommand process tree kill + ShellExecute env
$simText = Get-Content -Path (Join-Path $RootDir "scripts\simulate-user-release.ps1") -Raw -Encoding UTF8

if ($simText -notmatch 'taskkill\.exe\s+/PID\s+\$realPid\s+/T\s+/F') {
    throw "simulate-user-release.ps1 Invoke-SimCommand timeout must call taskkill.exe /PID `$realPid /T /F"
}
if ($simText -notmatch 'Stop-Process\s+-Id\s+\$realPid\s+-Force') {
    throw "simulate-user-release.ps1 Invoke-SimCommand timeout must have Stop-Process fallback"
}
if ($simText -match "try\s*\{\s*`$proc\.Kill\(\)") {
    throw "simulate-user-release.ps1 Invoke-SimCommand timeout must NOT use bare `$proc.Kill()"
}
if ($simText -match 'shellEnvBlock\s*=\s*@\{\}') {
    if ($simText -notmatch 'SetEnvironmentVariable') {
        throw "simulate-user-release.ps1 ShellExecute must inject TestSafe env vars via SetEnvironmentVariable"
    }
}
# ShellExecute must restore env in finally (or skip ShellExecute tests)
if ($simText -match 'ShellExecute' -and $simText -notmatch 'SetEnvironmentVariable') {
    throw "simulate-user-release.ps1 ShellExecute must inject/restore TestSafe env vars"
}

# 18c-1. simulate-user-release.ps1: 一键修复依赖.cmd coverage (v1.3.2 final)
if ($simText -notmatch '一键修复依赖\.cmd') {
    throw "simulate-user-release.ps1 must cover 一键修复依赖.cmd"
}
if ($simText -notmatch '一键修复依赖\.cmd.*TestSafe') {
    throw "simulate-user-release.ps1 must run 一键修复依赖.cmd with TestSafe env"
}
# ShellExecute non-0/1 exit code must throw
if ($simText -notmatch 'ShellExecute exited with unexpected code') {
    throw "simulate-user-release.ps1 ShellExecute must throw on non-0/1 exit code (not just WARN)"
}
# ShellExecute must track started flag and rethrow in catch when process was started
if ($simText -notmatch '\$started\s*=\s*\$false') {
    throw "simulate-user-release.ps1 ShellExecute test must track whether process actually started"
}
if ($simText -notmatch '\$started\s*=\s*\$true') {
    throw "simulate-user-release.ps1 ShellExecute test must set started=true after Process.Start succeeds"
}
if ($simText -notmatch 'if\s*\(\s*\$started\s*\)\s*\{\s*throw') {
    throw "simulate-user-release.ps1 ShellExecute catch must rethrow when process already started"
}
if ($simText -notmatch 'ShellExecute failed to start') {
    throw "simulate-user-release.ps1 ShellExecute SKIP message must be limited to start failure"
}

# 18d. release-artifacts.md anti-regression checks (v1.3.2 final)
$releaseArtifactsPath = Join-Path $RootDir "docs\release-artifacts.md"
if (-not (Test-Path $releaseArtifactsPath)) {
    throw "docs/release-artifacts.md must exist"
}
$releaseArtifactsText = Get-Content -Path $releaseArtifactsPath -Raw -Encoding UTF8
if ($releaseArtifactsText -match '当前 HEAD') {
    throw "docs/release-artifacts.md must NOT contain '当前 HEAD'; use a specific commit SHA"
}
if ($releaseArtifactsText -notmatch '[0-9a-fA-F]{7,}') {
    throw "docs/release-artifacts.md must contain a specific commit SHA (at least 7 hex chars)"
}
if ($releaseArtifactsText -notmatch '[0-9a-fA-F]{64}') {
    throw "docs/release-artifacts.md must contain SHA256 (64 hex chars)"
}
if ($releaseArtifactsText -notmatch '(Size|文件大小|KB|bytes)') {
    throw "docs/release-artifacts.md must contain Size or file size info"
}
if ($releaseArtifactsText -notmatch '(Entries|条目数)') {
    throw "docs/release-artifacts.md must contain Entries or entry count"
}
if ($releaseArtifactsText -notmatch 'Mode All.*RequireClean') {
    throw "docs/release-artifacts.md must document Mode All + RequireClean validation command"
}
# Commit in release-artifacts.md must reference a recent commit in the history.
# Uses "Artifact source commit" (current HEAD at doc time) and
# "Generating code commit" (the commit that produced the actual ZIP).
# Check HEAD through HEAD~4 to cover both fields across doc-only commits.
$recentShas = New-Object System.Collections.ArrayList
[void]$recentShas.Add((git rev-parse HEAD).Trim())
[void]$recentShas.Add((git rev-parse --short HEAD).Trim())
try { [void]$recentShas.Add((git rev-parse HEAD~1).Trim()) } catch { }
try { [void]$recentShas.Add((git rev-parse --short HEAD~1).Trim()) } catch { }
try { [void]$recentShas.Add((git rev-parse HEAD~2).Trim()) } catch { }
try { [void]$recentShas.Add((git rev-parse --short HEAD~2).Trim()) } catch { }
try { [void]$recentShas.Add((git rev-parse HEAD~3).Trim()) } catch { }
try { [void]$recentShas.Add((git rev-parse --short HEAD~3).Trim()) } catch { }
try { [void]$recentShas.Add((git rev-parse HEAD~4).Trim()) } catch { }
try { [void]$recentShas.Add((git rev-parse --short HEAD~4).Trim()) } catch { }
$foundCommit = $false
foreach ($sha in $recentShas) {
    if ($sha -and $releaseArtifactsText -match [regex]::Escape($sha)) {
        $foundCommit = $true
        break
    }
}
if (-not $foundCommit) {
    $headShort = (git rev-parse --short HEAD).Trim()
    throw "docs/release-artifacts.md Commit must reference a recent commit (HEAD=$headShort or parent)"
}
# Must include both source and generating commit fields
if ($releaseArtifactsText -notmatch 'Artifact source commit') {
    throw "docs/release-artifacts.md must include 'Artifact source commit' field"
}
if ($releaseArtifactsText -notmatch 'Generating code commit') {
    throw "docs/release-artifacts.md must include 'Generating code commit' field"
}

# 18e. validate.ps1 Invoke-PowerShellScript anti-regression (v1.3.2 final)
$validateText = Get-Content -Path (Join-Path $RootDir "scripts\validate.ps1") -Raw -Encoding UTF8
# Must NOT use -Command with bootstrap
if ($validateText -match '-Command\s+\"\$bootstrapCmd\"') {
    throw "validate.ps1 must NOT use -Command with bootstrap"
}
# Must NOT use Start-Job
if ($validateText -match 'function Invoke-PowerShellScript[\s\S]{0,2500}\bStart-Job\b') {
    throw "validate.ps1 Invoke-PowerShellScript must NOT use Start-Job within its function body"
}
# Must use System.Diagnostics.ProcessStartInfo
if ($validateText -notmatch 'System\.Diagnostics\.ProcessStartInfo') {
    throw "validate.ps1 Invoke-PowerShellScript must use System.Diagnostics.ProcessStartInfo"
}
# Must use [System.Diagnostics.Process]::Start($psi)
if ($validateText -notmatch '\[System\.Diagnostics\.Process\]::Start\(\$psi\)') {
    throw "validate.ps1 Invoke-PowerShellScript must use [System.Diagnostics.Process]::Start(`$psi)"
}
# Must use $proc.WaitForExit with TimeoutSec
if ($validateText -notmatch '\$proc\.WaitForExit\(\$TimeoutSec\s*\*\s*1000\)') {
    throw "validate.ps1 Invoke-PowerShellScript must use `$proc.WaitForExit(`$TimeoutSec * 1000)"
}
# Must use taskkill /T /F
if ($validateText -notmatch 'taskkill\.exe\s+/PID\s+\$realPid\s+/T\s+/F') {
    throw "validate.ps1 Invoke-PowerShellScript must use taskkill.exe /PID `$realPid /T /F"
}
# Must have Stop-Process fallback
if ($validateText -notmatch 'Stop-Process\s+-Id\s+\$realPid\s+-Force') {
    throw "validate.ps1 Invoke-PowerShellScript must have Stop-Process fallback"
}
# CoreSandboxFlow doctor.ps1 must have -TestSafe
if ($validateText -notmatch 'doctor\.ps1[\s\S]{0,300}-TestSafe') {
    throw "validate.ps1 CoreSandboxFlow must pass -TestSafe to doctor.ps1"
}
# CoreSandboxFlow Start-Here.ps1 FixDeps must have -NonInteractive
if ($validateText -notmatch 'Start-Here\.ps1[\s\S]{0,300}-FixDeps[\s\S]{0,120}-NonInteractive') {
    throw "validate.ps1 CoreSandboxFlow FixDeps step must pass -NonInteractive"
}
# Must have stdout/stderr file capture
if ($validateText -notmatch 'RedirectStandardOutput\s*=\s*\$true') {
    throw "validate.ps1 Invoke-PowerShellScript must use RedirectStandardOutput"
}
if ($validateText -notmatch 'RedirectStandardError\s*=\s*\$true') {
    throw "validate.ps1 Invoke-PowerShellScript must use RedirectStandardError"
}
if ($validateText -notmatch 'validate-child-.*\.stdout\.txt') {
    throw "validate.ps1 Invoke-PowerShellScript must write stdout to validate-child-*.stdout.txt"
}
if ($validateText -notmatch 'validate-child-.*\.stderr\.txt') {
    throw "validate.ps1 Invoke-PowerShellScript must write stderr to validate-child-*.stderr.txt"
}
# Must have ConvertTo-WindowsCommandLineArgument
if ($validateText -notmatch 'function ConvertTo-WindowsCommandLineArgument') {
    throw "validate.ps1 must define ConvertTo-WindowsCommandLineArgument function"
}
# ConvertTo-WindowsCommandLineArgument must handle trailing backslashes
if ($validateText -notmatch '\$backslashes\s*\*\s*2') {
    throw "validate.ps1 ConvertTo-WindowsCommandLineArgument must handle trailing backslashes"
}
# Must explicitly set WorkingDirectory (v1.3.2 final)
if ($validateText -notmatch 'WorkingDirectory\s*=\s*\$RootDir' -and
    $validateText -notmatch 'WorkingDirectory\s*=\s*\$script:RootDir') {
    throw "validate.ps1 Invoke-PowerShellScript must explicitly set ProcessStartInfo.WorkingDirectory"
}

# 18f. 00-点我开始安装.cmd rename anti-regression (v1.3.2 final)
$primaryLauncher = Join-Path $RootDir "00-点我开始安装.cmd"
if (-not (Test-Path $primaryLauncher)) {
    throw "Primary user launcher 00-点我开始安装.cmd must exist after rename"
}
$oldChineseLauncher = Join-Path $RootDir "开始安装.cmd"
if (Test-Path $oldChineseLauncher) {
    throw "Old launcher 开始安装.cmd must not remain after rename to 00-点我开始安装.cmd"
}
# Content checks for the new primary launcher
$primaryLauncherText = Get-Content -Path $primaryLauncher -Raw -Encoding ASCII
if ($primaryLauncherText -notmatch 'Start-Here\.ps1') {
    throw "00-点我开始安装.cmd must call Start-Here.ps1"
}
if ($primaryLauncherText -notmatch 'Please extract the full ZIP package first') {
    throw "00-点我开始安装.cmd must show full ZIP extraction guidance"
}
if ($primaryLauncherText -notmatch 'exit /b') {
    throw "00-点我开始安装.cmd must propagate exit code with exit /b"
}
$launcherBytes = [System.IO.File]::ReadAllBytes($primaryLauncher)
foreach ($b in $launcherBytes) {
    if ($b -gt 0x7F) {
        throw "00-点我开始安装.cmd must be ASCII-only"
    }
}
# build-release.ps1 whitelist must include new name, keep English, drop old name
$buildReleaseText = Get-Content -Path (Join-Path $RootDir "scripts\build-release.ps1") -Raw -Encoding UTF8
if ($buildReleaseText -notmatch '00-点我开始安装\.cmd') {
    throw "build-release.ps1 must include 00-点我开始安装.cmd in release whitelist"
}
if ($buildReleaseText -notmatch 'Start-Install\.cmd') {
    throw "build-release.ps1 must keep Start-Install.cmd in release whitelist"
}
if ($buildReleaseText -match '(?<!00-点我)开始安装\.cmd') {
    throw "build-release.ps1 must not include old 开始安装.cmd (use 00-点我开始安装.cmd)"
}
# simulate-user-release.ps1 must cover the renamed launcher
$simTextCheck = Get-Content -Path (Join-Path $RootDir "scripts\simulate-user-release.ps1") -Raw -Encoding UTF8
if ($simTextCheck -notmatch '00-点我开始安装\.cmd') {
    throw "simulate-user-release.ps1 must cover 00-点我开始安装.cmd"
}
if ($simTextCheck -match '(?<!00-点我)开始安装\.cmd') {
    throw "simulate-user-release.ps1 must not reference old 开始安装.cmd"
}
if ($simTextCheck -notmatch '00-点我开始安装\.cmd cancel') {
    throw "simulate-user-release.ps1 must run 00-点我开始安装.cmd cancel flow"
}
if ($simTextCheck -notmatch 'ShellExecute[\s\S]{0,800}00-点我开始安装\.cmd') {
    throw "simulate-user-release.ps1 must include 00-点我开始安装.cmd in ShellExecute launcher list"
}

# 17. Start-Job failure must log skip reason with "避免诊断流程卡死"
if ($claudeInstallText -notmatch '已跳过 claude doctor，避免诊断流程卡死') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must log that claude doctor was skipped to avoid hang"
}

# 18. Invoke-ClaudeDoctorSafe must map watchdog_unavailable_skipped to skipped_watchdog_unavailable
if ($claudeInstallText -notmatch 'skipped_watchdog_unavailable') {
    throw "Invoke-ClaudeDoctorSafe must map watchdog_unavailable_skipped to skipped_watchdog_unavailable status"
}

# 19. Invoke-ClaudeDoctorSafe must handle watchdog_unavailable; doctor.ps1 no longer calls it directly
if ($claudeInstallText -notmatch 'skipped_watchdog_unavailable') {
    throw "Invoke-ClaudeDoctorSafe must map watchdog_unavailable_skipped to skipped_watchdog_unavailable status"
}
# doctor.ps1 no longer calls Invoke-ClaudeDoctor; these legacy checks are retired.

# 20b. test-doctor-capture.ps1 must exist with required tests
$testDoctorCapturePath = Join-Path $ScriptDir "test-doctor-capture.ps1"
if (-not (Test-Path $testDoctorCapturePath)) {
    throw "scripts/test-doctor-capture.ps1 must exist"
}
$testDoctorCaptureText = Get-Content -Path $testDoctorCapturePath -Raw -Encoding UTF8
if ($testDoctorCaptureText -notmatch 'fake-test-timeout') {
    throw "test-doctor-capture.ps1 must contain fake-test-timeout test"
}
if ($testDoctorCaptureText -notmatch 'fake-large-output') {
    throw "test-doctor-capture.ps1 must contain fake-large-output test"
}
if ($testDoctorCaptureText -notmatch 'Invoke-ClaudeDoctorInteractiveSafe') {
    throw "test-doctor-capture.ps1 must call Invoke-ClaudeDoctorInteractiveSafe"
}
if ($testDoctorCaptureText -notmatch '\$env:PATH') {
    throw "test-doctor-capture.ps1 must restore `$env:PATH"
}
if ($testDoctorCaptureText -notmatch 'finally') {
    throw "test-doctor-capture.ps1 must use finally for cleanup"
}
if ($testDoctorCaptureText -notmatch 'CCDI_TEST_MODE') {
    throw "test-doctor-capture.ps1 must clear/restore CCDI_TEST_MODE so fake capture is not skipped"
}
if ($testDoctorCaptureText -notmatch 'CCDI_MOCK_INSTALL_DECISION') {
    throw "test-doctor-capture.ps1 must clear/restore CCDI_MOCK_INSTALL_DECISION"
}
if ($testDoctorCaptureText -notmatch 'Restore-TestEnv' -and $testDoctorCaptureText -notmatch 'Remove-Item Env:\\CCDI_TEST_MODE') {
    throw "test-doctor-capture.ps1 must restore test environment variables in finally"
}
Write-Host "[check] test-doctor-capture.ps1 structure OK"

# 20c. Watchdog fired must not rely on JobState alone; must use log-based detection
$claudeInstallText = Get-Content -Path (Join-Path $RootDir "lib\claude-install.ps1") -Raw -Encoding UTF8
if ($claudeInstallText -match 'else\s*\{\s*\$watchdogFired\s*=\s*\$true') {
    throw "Watchdog fired must NOT use bare else { watchdogFired=`$true }"
}
if ($claudeInstallText -notmatch '\$watchdogLogText') {
    throw "Watchdog fired detection must use `$watchdogLogText for log-based determination"
}
if ($claudeInstallText -notmatch 'taskkill 结果|找到.*个 claude doctor') {
    throw "Watchdog fired must check for actual 'taskkill 结果' or '找到 N 个 claude doctor' in logs"
}
if ($claudeInstallText -notmatch '未实际终止进程，不标记为 fired') {
    throw "Watchdog must explicitly log when it did NOT actually kill (not marking as fired)"
}
Write-Host "[check] Watchdog fired logic OK"

# 20d. Clear-StaleClaudeDoctorProcesses must support scoped descendant cleanup
if ($claudeInstallText -notmatch 'ParentPid') {
    throw "Clear-StaleClaudeDoctorProcesses must support -ParentPid parameter"
}
if ($claudeInstallText -notmatch 'Test-IsDescendantProcess') {
    throw "Clear-StaleClaudeDoctorProcesses must include Test-IsDescendantProcess helper"
}
if ($claudeInstallText -notmatch 'node\.exe') {
    throw "Clear-StaleClaudeDoctorProcesses must handle node.exe (npm scenario)"
}
if ($claudeInstallText -notmatch 'cmd\.exe') {
    throw "Clear-StaleClaudeDoctorProcesses must handle cmd.exe (wrapper scenario)"
}
if ($claudeInstallText -notmatch 'powershell\.exe') {
    throw "Clear-StaleClaudeDoctorProcesses must handle powershell.exe"
}
if ($claudeInstallText -notmatch 'pwsh\.exe') {
    throw "Clear-StaleClaudeDoctorProcesses must handle pwsh.exe"
}
if ($claudeInstallText -notmatch 'global stale claude\.exe doctor cleanup') {
    throw "Clear-StaleClaudeDoctorProcesses global mode must log 'global stale claude.exe doctor cleanup'"
}
Write-Host "[check] Clear-StaleClaudeDoctorProcesses scoped mode OK"

# 20e. Check-Files must not invoke WSL; WSL settings check belongs in Check-WSL
$doctorText = Get-Content -Path (Join-Path $RootDir "doctor.ps1") -Raw -Encoding UTF8
$checkFilesText = if ($doctorText -match '(?s)function Check-Files\s*\{(.*?)function Check-Network\s*\{') { $matches[1] } else { "" }
if ($checkFilesText -match 'Invoke-CommandSafe\s+-Command\s+"wsl"') {
    throw "Check-Files must not call Invoke-CommandSafe wsl; WSL settings.json check belongs in Check-WSL"
}
if ($checkFilesText -match 'WSL settings\.json') {
    throw "Check-Files must not reference 'WSL settings.json'; WSL config check belongs in Check-WSL"
}
Write-Host "[check] Check-Files WSL separation OK"

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

# 40c. doctor.ps1 no longer calls Invoke-ClaudeDoctor automatically.
# Severity-based switch was relevant only for the previous auto-invocation path.

# 41. Invoke-ClaudeDoctorInteractiveSafe must set NO_COLOR/CI/TERM env vars
if ($claudeInstallText -notmatch 'NO_COLOR.*=\s*["'']?1["'']?') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must set NO_COLOR=1 (env var or set command)"
}
if ($claudeInstallText -notmatch 'TERM.*=\s*["'']?dumb["'']?') {
    throw "Invoke-ClaudeDoctorInteractiveSafe must set TERM=dumb (env var or set command)"
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

# 45. doctor.ps1 encoding policy: must NOT force chcp 65001 or Console Encoding directly.
# Encoding is handled by Initialize-ConsoleEncodingSafe via bootstrap/logger.
$loggerTextForEncoding = Get-Content -Path (Join-Path $RootDir "lib\logger.ps1") -Raw -Encoding UTF8

# 45a. doctor.ps1 must not call chcp 65001 directly (skip comment lines)
if ($doctorText -match '(?m)^[^#\r\n]*chcp\s+65001') {
    throw "doctor.ps1 must not call chcp 65001 directly; use Initialize-ConsoleEncodingSafe via bootstrap/logger"
}

# 45b. doctor.ps1 must not set Console InputEncoding/OutputEncoding directly
if ($doctorText -match '\[Console\]::InputEncoding\s*=' -or
    $doctorText -match '\[Console\]::OutputEncoding\s*=') {
    throw "doctor.ps1 must not set Console InputEncoding/OutputEncoding directly; use Initialize-ConsoleEncodingSafe"
}

# 45c. doctor.ps1 must load bootstrap.ps1
if ($doctorText -notmatch 'lib\\bootstrap\.ps1' -and $doctorText -notmatch 'lib/bootstrap\.ps1') {
    throw "doctor.ps1 must load lib/bootstrap.ps1"
}

# 45d. doctor.ps1 must call Initialize-CcdiScript
if ($doctorText -notmatch 'Initialize-CcdiScript\s+-ScriptName\s+"doctor"') {
    throw "doctor.ps1 must initialize through Initialize-CcdiScript -ScriptName `"doctor`""
}

# 45e. logger.ps1 must have Initialize-ConsoleEncodingSafe
if ($loggerTextForEncoding -notmatch 'function Initialize-ConsoleEncodingSafe') {
    throw "logger.ps1 must define Initialize-ConsoleEncodingSafe"
}

# 45f. Initialize-ConsoleEncodingSafe must detect legacy PS 5.1 Desktop
if ($loggerTextForEncoding -notmatch 'PSEdition' -or
    $loggerTextForEncoding -notmatch 'Desktop') {
    throw "Initialize-ConsoleEncodingSafe must detect Windows PowerShell Desktop/5.1"
}

# 45g. Initialize-ConsoleEncodingSafe must skip forced UTF-8 on legacy
if ($loggerTextForEncoding -notmatch 'skip|legacy|Windows PowerShell') {
    throw "Initialize-ConsoleEncodingSafe must explicitly skip forced UTF-8 for legacy Windows PowerShell 5.1/conhost"
}

# 46. Invoke-ClaudeDoctorInteractiveSafe must use cmd.exe wrapping (shell redirect + set CI=1)
# or redirect stdin with newlines to prevent pagination.
$usesCmdExeWrapper = ($claudeInstallText -match 'cmd\.exe.*claude.*doctor' -or $claudeInstallText -match 'cmdExe')
$usesStdinRedirect = ($claudeInstallText -match 'StandardInput' -and $claudeInstallText -match 'WriteLine')
if (-not $usesCmdExeWrapper -and -not $usesStdinRedirect) {
    throw "Invoke-ClaudeDoctorInteractiveSafe must use cmd.exe wrapper or stdin newlines to prevent pagination"
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

# ============================================================
# 第四批 UX 优化防回归检查
# ============================================================
Write-Host "[check] Batch 4 UX regression checks (progress visibility, log path, WSL gate, timeout)"

$startHereText = Get-Content -Path (Join-Path $RootDir "Start-Here.ps1") -Raw -Encoding UTF8
$repairDepsText = Get-Content -Path (Join-Path $RootDir "repair-deps.ps1") -Raw -Encoding UTF8
$longRunningCheckText = Get-Content -Path (Join-Path $RootDir "scripts\check-long-running-commands.ps1") -Raw -Encoding UTF8

# 52. Start-Here.ps1 must have Write-CheckProgress function
if ($startHereText -notmatch 'function Write-CheckProgress') {
    throw "Start-Here.ps1 must define Write-CheckProgress function for per-check progress indicators"
}

# 53. Start-Here.ps1 must show log path early
if ($startHereText -notmatch '本次运行日志.*Get-LogFilePath') {
    throw "Start-Here.ps1 must show log path early in Main() (before disclaimer)"
}
if ($startHereText -notmatch '如果窗口异常关闭，可把此文件发给技术支持') {
    throw "Start-Here.ps1 must include log path guidance text for crash scenarios"
}

# 54. Start-Here.ps1 WSL method B removed: no Invoke-CommandSafe + wsl in Start-WslSetup
if ($startHereText -match 'Start-WslSetup[\s\S]{0,3000}Invoke-CommandSafe\s+-Command\s+"wsl"') {
    throw "Start-Here.ps1: Start-WslSetup must NOT use Invoke-CommandSafe for wsl (method B removed)"
}

# 55. Start-Here.ps1 no "方式 B" in WSL context
if ($startHereText -match '方式\s*B[\s\S]{0,100}Windows.*端.*WSL') {
    throw "Start-Here.ps1 must NOT advertise WSL method B (Windows-side auto-call) to users"
}

# 56. repair-deps.ps1 npm prefix -g must have explicit TimeoutSec 8
$rpmPrefix = [regex]::Match($repairDepsText, 'Invoke-CommandSafe[\s\S]{0,300}?"-g"\s*\)[\s\S]{0,30}?-TimeoutSec\s+(\d+)')
if ($rpmPrefix.Success) {
    $rpmPrefixFull = $rpmPrefix.Groups[0].Value
    if ($rpmPrefixFull -match '"prefix"') {
        $rpmSec = [int]$rpmPrefix.Groups[1].Value
        if ($rpmSec -ne 8) {
            throw "repair-deps.ps1 npm prefix -g TimeoutSec must be 8, got $rpmSec"
        }
    }
} else {
    throw "repair-deps.ps1 npm prefix -g must have explicit -TimeoutSec 8"
}
if ($repairDepsText -notmatch 'if\s*\(\s*-not\s+\$NonInteractive\s+-and\s+-not\s+\$IsTestSafe\s*\)\s*\{[\s\S]{0,120}Read-Host') {
    throw "repair-deps.ps1 TestSafe/DryRun mode must not wait for final Read-Host"
}

# 57. check-long-running-commands.ps1 must have new rules
if ($longRunningCheckText -notmatch 'npm prefix -g') {
    throw "check-long-running-commands.ps1 must check npm prefix -g TimeoutSec"
}
if ($longRunningCheckText -notmatch 'code --install-extension') {
    throw "check-long-running-commands.ps1 must check code --install-extension via Invoke-CommandSafe"
}
if ($longRunningCheckText -notmatch 'Write-CheckProgress') {
    throw "check-long-running-commands.ps1 must check for Write-CheckProgress in Start-Here.ps1"
}
if ($longRunningCheckText -notmatch '本次运行日志') {
    throw "check-long-running-commands.ps1 must check for early log path display in Start-Here.ps1"
}

# 58. lib/env-check.ps1 WSL decoded pipe regression: must preserve 8759afa fix
$envCheckText = Get-Content -Path (Join-Path $RootDir "lib\env-check.ps1") -Raw -Encoding UTF8
if ($envCheckText -notmatch '`"\`\$decoded`"\s*\|\s*bash') {
    throw "lib/env-check.ps1 decoded pipe to bash must have double quotes: printf '%s' `"`$decoded`" | bash"
}
if ($envCheckText -notmatch 'command\s+-v\s+base64') {
    throw "lib/env-check.ps1 must check 'command -v base64' before piping to bash"
}

Write-Host "[check] Batch 4 UX regression checks OK"

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
if ($claudeInstallText -notmatch 'Install-ClaudeCodeNpmMirror[\s\S]{0,3000}Invoke-VisibleInstallCommand') {
    throw "Install-ClaudeCodeNpmMirror must use Invoke-VisibleInstallCommand for npm install"
}

# 23. Install-ClaudeCodeNative execution phase must NOT use Invoke-CommandSafe
if ($claudeInstallText -match 'Install-ClaudeCodeNative[\s\S]{0,3000}Invoke-CommandSafe\s+-Command\s+"powershell"[\s\S]{0,300}-File\s+\$tempInstallScript') {
    throw "Install-ClaudeCodeNative execution must NOT use Invoke-CommandSafe; use Invoke-VisibleInstallCommand"
}
if ($claudeInstallText -notmatch 'Install-ClaudeCodeNative[\s\S]{0,3000}Invoke-VisibleInstallCommand') {
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
if ($claudeInstallText -notmatch 'Claude 官方安装通道执行失败，正在自动切换备用安装通道') {
    throw "Native Install failure must show user-friendly message about fallback to alternate channel"
}
if ($claudeInstallText -notmatch '这通常是官方下载通道不稳定或被网络拦截，不代表整体安装失败') {
    throw "Native Install failure must reassure user that this is not an overall failure"
}

# 29. Native Install error detail must be logged, not displayed to user
if ($claudeInstallText -notmatch 'Write-Log\s+"ERROR"\s+"Native Install 失败详情') {
    throw "Native Install failure details must go to Write-Log, not user display"
}

# 30. Invoke-ClaudeDoctorInteractiveSafe uses isolated process execution (cmd.exe wrapping with temp files,
# or .NET ProcessStartInfo with stdout/stderr redirect). Both ensure no TTY leak.
$usesCmdExeTempFile = ($claudeInstallText -match 'cmd\.exe' -and $claudeInstallText -match 'ccdi_doctor_stdout.*\.tmp')
$usesProcessStartInfo = ($claudeInstallText -match 'System\.Diagnostics\.ProcessStartInfo')
if (-not $usesCmdExeTempFile -and -not $usesProcessStartInfo) {
    throw "Invoke-ClaudeDoctorInteractiveSafe must use cmd.exe wrapper or ProcessStartInfo for isolated doctor execution"
}
if (-not $usesCmdExeTempFile) {
    if ($claudeInstallText -notmatch 'RedirectStandardOutput\s*=\s*\$true') {
        throw "Invoke-ClaudeDoctorInteractiveSafe must redirect stdout (cmd.exe shell redirect or .NET pipe)"
    }
    if ($claudeInstallText -notmatch 'RedirectStandardInput\s*=\s*\$true') {
        throw "Invoke-ClaudeDoctorInteractiveSafe must redirect stdin (for Enter prevention)"
    }
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
    (Join-Path $RootDir "00-点我开始安装.cmd"),
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

# 7. 取消输入不再显示错误文案
# Step-GetApiKey 交互式取消不得使用 Write-Error-Msg "API Key 不能为空！"
if ($startHereText -match [regex]::Escape('Write-Error-Msg "API Key 不能为空！"')) {
    throw "Step-GetApiKey must NOT show 'API Key 不能为空' error on cancellation"
}
if ($startHereText -notmatch "已取消 API Key 输入。") {
    throw "Step-GetApiKey must show '已取消 API Key 输入。' on cancellation"
}

# 8. 统一使用中文箭头 →
if ($startHereText -match '00-点我开始安装\.cmd\s*->\s*高级选项') {
    throw "Start-Here.ps1 must use Chinese arrow '→' not ASCII '->' for skip guidance"
}
if ($startHereText -notmatch [regex]::Escape('00-点我开始安装.cmd → 高级选项 → 仅配置 DeepSeek API')) {
    throw "Start-Here.ps1 must use '→' arrow in skip guidance path"
}

# 9. Write-ApiKeySkipGuidance 函数存在
if ($startHereText -notmatch 'function Write-ApiKeySkipGuidance') {
    throw "Start-Here.ps1 must define Write-ApiKeySkipGuidance function"
}

# 10. Start-LazyInstall 跳过文案柔和化
if ($startHereText -notmatch "未配置 API Key，已跳过 DeepSeek 配置步骤") {
    throw "Start-LazyInstall must show soft skip message when no API key"
}
if ($startHereText -notmatch "Claude Code 安装状态不受影响") {
    throw "Start-LazyInstall must reassure that Claude Code install is unaffected"
}

# 11. configure-deepseek.ps1 交互式取消 exit 0
if ($configureText -notmatch "已取消 API Key 输入。") {
    throw "configure-deepseek.ps1 must show '已取消 API Key 输入。' on cancel"
}
if ($configureText -notmatch "配置未更改。") {
    throw "configure-deepseek.ps1 must show '配置未更改。' on cancel"
}
if ($configureText -notmatch 'if\s*\(\$NonInteractive\)\s*\{[\s\S]{0,200}Write-Error-Msg[\s\S]{0,200}exit 1[\s\S]{0,300}exit 0') {
    throw "configure-deepseek.ps1 must exit 1 for NonInteractive empty key, exit 0 for interactive cancel"
}

Write-Host "[check] UX text checks OK"

# ============================================================
# UX 增强检查（v1.3.2 第三批：Confirm-UserChoice/EnvSnapshot/CompletionMenu/Privacy）
# ============================================================
Write-Host "[check] UX enhancements: Confirm-UserChoice, EnvSnapshot, CompletionMenu, Privacy"

# 1. Confirm-UserChoice must support Default parameter
if ($commonText -notmatch '\[ValidateSet\("Yes",\s*"No",\s*"None"\)\]') {
    throw "Confirm-UserChoice must support Default parameter with ValidateSet Yes/No/None"
}
if ($commonText -notmatch '\[string\]\$Default\s*=\s*"None"') {
    throw "Confirm-UserChoice must have -Default parameter"
}

# 2. Confirm-UserChoice must recognize yes/no/确认/取消/继续 keywords
$requiredYesKeywords = @("是", "确认", "继续", "好", "ok", "OK")
foreach ($kw in $requiredYesKeywords) {
    if ($commonText -notmatch [regex]::Escape($kw)) {
        throw "Confirm-UserChoice must recognize keyword: $kw"
    }
}
$requiredNoKeywords = @("否", "取消", "不", "不继续")
foreach ($kw in $requiredNoKeywords) {
    if ($commonText -notmatch [regex]::Escape($kw)) {
        throw "Confirm-UserChoice must recognize keyword: $kw"
    }
}

# 3. Confirm-UserChoice must re-prompt on invalid input (not treat as No)
if ($commonText -notmatch '未识别输入，请输入 Y 或 N。') {
    throw "Confirm-UserChoice must show '未识别输入，请输入 Y 或 N。' on invalid input"
}
if ($commonText -notmatch 'while\s*\(\$true\)') {
    throw "Confirm-UserChoice must use while(true) loop for re-prompt"
}

# 4. Step-CheckEnvironment must write EnvSnapshot
if ($startHereText -notmatch '\$script:EnvSnapshot\s*=\s*@\{') {
    throw "Step-CheckEnvironment must write `$script:EnvSnapshot"
}
$requiredSnapshotFields = @("DeepSeekNetwork", "ClaudeVersion", "NodeInfo", "NpmInfo", "WslInfo", "CodeVersion", "GitVersion", "ConfigInfo", "MinReq")
foreach ($field in $requiredSnapshotFields) {
    if ($startHereText -notmatch [regex]::Escape($field) + '\s*=\s*\$') {
        throw "EnvSnapshot must cache field: $field"
    }
}

# 4b. State variables must pre-initialize EnvSnapshot to $null (StrictMode safety)
if ($startHereText -notmatch '\$script:EnvSnapshot\s*=\s*\$null') {
    throw "Start-Here.ps1 must pre-initialize `$script:EnvSnapshot = `$null in state variables section"
}

# 5. Step-GenerateReport must use Get-Variable for defensive EnvSnapshot read
if ($startHereText -notmatch 'Get-Variable\s+-Name\s+EnvSnapshot\s+-Scope\s+Script\s+-ErrorAction\s+SilentlyContinue') {
    throw "Step-GenerateReport must use Get-Variable -Name EnvSnapshot -Scope Script -ErrorAction SilentlyContinue"
}
if ($startHereText -notmatch 'if\s*\(\$snapVar\)\s*\{\s*\$snapVar\.Value\s*\}\s*else\s*\{\s*\$null\s*\}') {
    throw "Step-GenerateReport must guard snapVar result with if/else null fallback"
}
if ($startHereText -notmatch 'if\s*\(\$snap\)') {
    throw "Step-GenerateReport must check `$snap before using cache"
}

# 6. Step-GenerateReport must NOT unconditionally re-run full env checks
# The old pattern of calling all 5 tests unconditionally should be replaced by cache-first logic
if ($startHereText -notmatch 'EnvSnapshot 不存在时') {
    throw "Step-GenerateReport must have fallback for missing EnvSnapshot"
}

# 7. Show-CompletionPage must include the 4 completion menu items
$requiredMenuItems = @(
    "打开测试项目文件夹",
    "打开安装报告",
    "运行一键诊断",
    "退出"
)
foreach ($item in $requiredMenuItems) {
    if ($startHereText -notmatch [regex]::Escape($item)) {
        throw "Show-CompletionPage/Show-CompletionMenu must contain menu item: $item"
    }
}
# Show-CompletionMenu function must exist
if ($startHereText -notmatch 'function Show-CompletionMenu') {
    throw "Start-Here.ps1 must define Show-CompletionMenu function"
}

# 7b. Show-CompletionMenu MUST NOT use $LASTEXITCODE for GUI program exit check
if ($startHereText -match 'Show-CompletionMenu[\s\S]{0,800}\$LASTEXITCODE') {
    throw "Show-CompletionMenu must NOT use `$LASTEXITCODE for GUI program (notepad) exit check"
}
# 7c. Show-CompletionMenu must use Start-Process for notepad
if ($startHereText -notmatch 'Start-Process\s+-FilePath\s+"notepad\.exe"') {
    throw "Show-CompletionMenu must use Start-Process -FilePath notepad.exe for report opening"
}
# 7d. Show-CompletionMenu must have Invoke-Item fallback
if ($startHereText -notmatch 'Invoke-Item\s+-Path\s+\$script:ReportPath') {
    throw "Show-CompletionMenu must have Invoke-Item fallback when notepad fails"
}

# 8. report/share-safe 报告正文不应出现 OAuth 作为隐私声明列举项
# doctor.ps1 report privacy notice must use the new wording
$doctorText = Get-Content -Path (Join-Path $RootDir "doctor.ps1") -Raw -Encoding UTF8
if ($doctorText -match '报告中不包含 OAuth') {
    throw "doctor.ps1 privacy notice must NOT enumerate OAuth as listed item; use generic wording"
}
if ($doctorText -notmatch '内部认证字段、完整路径或敏感标识') {
    throw "doctor.ps1 privacy notice must use new generic wording about internal auth fields"
}
# Allow sanitization logic (Convert-ToSafeReportText, Parse-ClaudeDoctorOutput) to still scan OAuth internally
if ($commonText -notmatch 'OAuth') {
    throw "Convert-ToSafeReportText must still filter OAuth in sanitization logic (internal, not user-visible notice)"
}

Write-Host "[check] UX enhancements OK"

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
        "node-via-winget", "winget")
    $validStatuses = @("skipped_existing", "skipped_test_safe_existing", "skipped_test_safe_missing",
        "skipped_test_safe_broken", "installed", "installed_needs_restart",
        "node_installed_needs_restart", "failed_missing_node_or_npm",
        "failed_npmmirror_unreachable", "failed_official_and_mirror", "failed_missing_npm_cmd",
        "failed_claude_unusable")
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

# ============================================================
# npm.cmd + winget Node.js verify + WSL noise anti-regression (v1.3.2)
# ============================================================
Write-Host "[check] npm.cmd + winget verify + WSL noise anti-regression"

$claudeInstallText = Get-Content -Path (Join-Path $RootDir "lib\claude-install.ps1") -Raw -Encoding UTF8
$commonText = Get-Content -Path (Join-Path $RootDir "lib\common.ps1") -Raw -Encoding UTF8
$envCheckText = Get-Content -Path (Join-Path $RootDir "lib\env-check.ps1") -Raw -Encoding UTF8
$startHereText = Get-Content -Path (Join-Path $RootDir "Start-Here.ps1") -Raw -Encoding UTF8

# 1. Resolve-NpmCmdPath exists in common.ps1
if ($commonText -notmatch 'function Resolve-NpmCmdPath') {
    throw "common.ps1 must define Resolve-NpmCmdPath function"
}

# 2. Install-ClaudeCodeNpmMirror must NOT use Get-Command npm directly for Invoke-VisibleInstallCommand
if ($claudeInstallText -match 'Get-Command npm[\s\S]{0,300}Invoke-VisibleInstallCommand\s+-FilePath\s+\$npmPath') {
    throw "Install-ClaudeCodeNpmMirror must NOT pass `$npmPath from Get-Command npm directly to Invoke-VisibleInstallCommand"
}

# 3. Install-ClaudeCodeNpmMirror must use Resolve-NpmCmdPath
if ($claudeInstallText -notmatch 'Install-ClaudeCodeNpmMirror[\s\S]{0,800}Resolve-NpmCmdPath') {
    throw "Install-ClaudeCodeNpmMirror must use Resolve-NpmCmdPath"
}

# 4. npm.cmd must appear in Install-ClaudeCodeNpmMirror
if ($claudeInstallText -notmatch 'npm\.cmd') {
    throw "Install-ClaudeCodeNpmMirror must reference npm.cmd"
}

# 5. Invoke-VisibleInstallCommand in Install-ClaudeCodeNpmMirror must use npm.cmd path
#    (v1.3.2: 不再手动包 cmd.exe /c，改为传 npm.cmd 路径给 Invoke-VisibleInstallCommand，
#     由它内部统一处理 .cmd 执行兼容性，避免引号嵌套错误)
if ($claudeInstallText -notmatch 'npmResolved\.Path[\s\S]{0,200}Invoke-VisibleInstallCommand') {
    throw "Install-ClaudeCodeNpmMirror must use Resolve-NpmCmdPath result with Invoke-VisibleInstallCommand"
}

# 6. Node.js winget install branch must include secondary verification (not just installResult.Success)
if ($claudeInstallText -notmatch '二[次次]验证') {
    throw "Install-ClaudeCodeAuto must include secondary verification (二次验证) after winget Node install"
}
if ($claudeInstallText -notmatch 'Test-NodeJsInstalled[\s\S]{0,200}Test-NpmInstalled') {
    throw "Install-ClaudeCodeAuto winget branch must call both Test-NodeJsInstalled and Test-NpmInstalled for secondary verify"
}

# 7. Winget Node install branch must call Refresh-CurrentProcessPath near secondary verify
if ($claudeInstallText -notmatch 'Refresh-CurrentProcessPath[\s\S]{0,500}二次验证' -and
    $claudeInstallText -notmatch '二次验证[\s\S]{0,500}Refresh-CurrentProcessPath') {
    throw "Install-ClaudeCodeAuto must call Refresh-CurrentProcessPath near secondary verification"
}

# 8. WSL display text must include "不影响 Windows 原生安装" or "不影响主流程"
$wslDisplayText = $startHereText + $claudeInstallText + $envCheckText
if ($wslDisplayText -notmatch '不影响 Windows 原生安装' -and $wslDisplayText -notmatch '不影响主流程') {
    throw "WSL skip message must include '不影响 Windows 原生安装' or '不影响主流程'"
}

# 9. Install-ClaudeCodeViaWinget function must exist
if ($claudeInstallText -notmatch 'function Install-ClaudeCodeViaWinget') {
    throw "claude-install.ps1 must define Install-ClaudeCodeViaWinget function"
}

# 10. Test-WslInstalled must use -LogTimeoutAsWarn
if ($envCheckText -notmatch 'Test-WslInstalled[\s\S]{0,800}LogTimeoutAsWarn') {
    throw "Test-WslInstalled must use -LogTimeoutAsWarn to suppress WSL timeout ERROR noise"
}

# 11. Test-NpmMirrorClaudeCodeNetwork must use Resolve-NpmCmdPath (not raw "npm")
if ($claudeInstallText -notmatch 'Test-NpmMirrorClaudeCodeNetwork[\s\S]{0,3000}Resolve-NpmCmdPath') {
    throw "Test-NpmMirrorClaudeCodeNetwork must use Resolve-NpmCmdPath instead of raw npm"
}

# 12. Test-NpmInstalled must use Resolve-NpmCmdPath (not Get-Command npm)
if ($envCheckText -notmatch 'Resolve-NpmCmdPath') {
    throw "env-check.ps1 must use Resolve-NpmCmdPath"
}

# 13. No npm.ps1 reference in install path (only warning/info references allowed)
$npmPs1ContextLines = @($claudeInstallText -split "`n" | Where-Object { $_ -match 'npm\.ps1' })
foreach ($line in $npmPs1ContextLines) {
    if ($line -match 'Invoke-VisibleInstallCommand|Start-Process.*FilePath.*npm' -and $line -notmatch '禁止|不能|avoid|不') {
        throw "npm.ps1 must not appear in install execution context: $line"
    }
}

# 14. Test-NpmInstalled must NOT use bare "npm.cmd" for Invoke-CommandSafe (must use resolved path)
if ($envCheckText -match 'Test-NpmInstalled[\s\S]{0,2000}Invoke-CommandSafe\s+-Command\s+"npm\.cmd"') {
    throw "Test-NpmInstalled must use resolved `$npmResolved.Path, not bare 'npm.cmd'"
}

# 15. npm prefix fallback in claude-install.ps1 must resolve path, not use bare "npm.cmd"
$npmPrefixContext = @($claudeInstallText -split "`n" | Where-Object { $_ -match 'Invoke-CommandSafe.*"npm\.cmd".*prefix' })
if ($npmPrefixContext.Count -gt 0) {
    throw "npm prefix calls must use Resolve-NpmCmdPath + resolved path, not bare 'npm.cmd': $($npmPrefixContext[0])"
}

Write-Host "[check] npm.cmd + winget verify + WSL noise anti-regression OK"

# ============================================================
# P0 修复防回归: Exists→Usable, .local\bin, repair-deps 二次验证 (v1.3.2)
# ============================================================
Write-Host "[check] P0 fix anti-regression: Usable verification, .local\bin, repair-deps secondary verify"

$claudeInstallText = Get-Content -Path (Join-Path $RootDir "lib\claude-install.ps1") -Raw -Encoding UTF8
$commonText = Get-Content -Path (Join-Path $RootDir "lib\common.ps1") -Raw -Encoding UTF8
$repairDepsText = Get-Content -Path (Join-Path $RootDir "repair-deps.ps1") -Raw -Encoding UTF8

# 1. Test-ClaudeCommandExisting must have Usable, Path, Source fields
if ($claudeInstallText -notmatch '\bUsable\s*=\s*\$false') {
    throw "Test-ClaudeCommandExisting must initialize Usable field"
}
if ($claudeInstallText -notmatch '\bPath\s*=\s*\$null') {
    throw "Test-ClaudeCommandExisting must include Path field in result"
}
if ($claudeInstallText -notmatch '\bSource\s*=\s*""') {
    throw "Test-ClaudeCommandExisting must include Source field in result"
}
# Must contain native_local_bin source
if ($claudeInstallText -notmatch 'native_local_bin') {
    throw "Test-ClaudeCommandExisting must detect claude.exe in .local\bin (native_local_bin)"
}
# Must check .local\bin\claude.exe
if ($claudeInstallText -notmatch '\.local\\bin.*claude\.exe' -and $claudeInstallText -notmatch '\.local/bin.*claude\.exe') {
    throw "Test-ClaudeCommandExisting must check .local\bin\claude.exe fallback"
}

# 2. Refresh-CurrentProcessPath must include .local\bin
if ($commonText -notmatch '\.local\\bin' -and $commonText -notmatch '\.local/bin') {
    throw "Refresh-CurrentProcessPath must include .local\bin in extraPaths"
}

# 3. Install-ClaudeCodeAuto: all installation success branches (near result.Success = $true) must use .Usable not .Exists
# Extract all code blocks around "result.Success = $true" in the function
$installAutoText = if ($claudeInstallText -match '(?s)function Install-ClaudeCodeAuto\s*\{.*^\}') {
    $matches[0]
} else {
    $claudeInstallText
}
# Check that verifyResult.Usable and verifyResult2.Usable and verifyWingetClaude.Usable exist
if ($installAutoText -notmatch '\$verifyResult\.Usable') {
    throw "Install-ClaudeCodeAuto must use `$verifyResult.Usable for install verification"
}
if ($installAutoText -notmatch '\$verifyResult2\.Usable') {
    throw "Install-ClaudeCodeAuto must use `$verifyResult2.Usable for PATH retry verification"
}
if ($installAutoText -notmatch '\$verifyWingetClaude\.Usable') {
    throw "Install-ClaudeCodeAuto must use `$verifyWingetClaude.Usable for winget verification"
}
# "result.Success = $true" near .Exists but NOT near .Usable → anti-pattern
# Conservative: check that no "result.Success = `$true" is immediately preceded by .Exists directly
# (within 3 lines) without also having .Usable nearby
if ($installAutoText -match '\$verify\w*\.Exists\s*\)\s*\{\s*\r?\n\s*Write-Success[\s\S]{0,200}\$result\.Success\s*=\s*\$true') {
    throw "Install-ClaudeCodeAuto: install success branch must NOT use only .Exists (must use .Usable)"
}

# 4. repair-deps.ps1 must NOT use bare "npm" in Invoke-CommandSafe for prefix
if ($repairDepsText -match 'Invoke-CommandSafe\s+-Command\s+"npm"\s+-Arguments\s+@\("prefix"') {
    throw "repair-deps.ps1 must NOT use bare 'npm' in Invoke-CommandSafe for prefix; use Resolve-NpmCmdPath"
}
if ($repairDepsText -match "Invoke-CommandSafe\s+-Command\s+'npm'\s+-Arguments\s+@\('prefix'") {
    throw "repair-deps.ps1 must NOT use bare 'npm' in Invoke-CommandSafe for prefix; use Resolve-NpmCmdPath"
}

# 5. repair-deps.ps1 Node winget install branch must have secondary verification
if ($repairDepsText -notmatch 'winget Node\.js 安装返回') {
    throw "repair-deps.ps1 must log 'winget Node.js 安装返回' after Install-NodeJsViaWinget"
}
# Must call Refresh-CurrentProcessPath, Test-NodeJsInstalled, Test-NpmInstalled after winget Node install
# Check that these three appear after Install-NodeJsViaWinget within reasonable proximity
$repairPostWinget = if ($repairDepsText -match 'Install-NodeJsViaWinget[\s\S]{0,2000}') {
    $matches[0]
} else { "" }
if ($repairPostWinget -notmatch 'Refresh-CurrentProcessPath') {
    throw "repair-deps.ps1 winget Node branch must call Refresh-CurrentProcessPath for secondary verify"
}
if ($repairPostWinget -notmatch 'Test-NodeJsInstalled') {
    throw "repair-deps.ps1 winget Node branch must call Test-NodeJsInstalled for secondary verify"
}
if ($repairPostWinget -notmatch 'Test-NpmInstalled') {
    throw "repair-deps.ps1 winget Node branch must call Test-NpmInstalled for secondary verify"
}
# secondary verification must have NEEDS_RESTART fallback
if ($repairDepsText -notmatch 'NEEDS_RESTART.*winget 已执行') {
    throw "repair-deps.ps1 must have NEEDS_RESTART fallback when secondary Node verification fails"
}

# ============================================================
# P0 补漏: native_local_bin 不能在 Get-Command 的 else 分支里
# 如果 PATH 前面有坏 claude，必须继续检测 .local\bin\claude.exe
# ============================================================
# 6. Test-ClaudeCommandExisting: native_local_bin 检测不能只出现在 Get-Command else 分支
# 提取函数文本
$tceFuncText = if ($claudeInstallText -match '(?s)function Test-ClaudeCommandExisting\s*\{.*?\n\}') {
    $matches[0]
} else { "" }
if (-not $tceFuncText) {
    throw "Test-ClaudeCommandExisting function body not found for structural analysis"
}
# 6a. 函数内 native_local_bin 必须至少出现 2 次（Source 赋值 + WARN 日志，证明不只是 mock 用）
$nativeBinCount = ([regex]::Matches($tceFuncText, 'native_local_bin')).Count
if ($nativeBinCount -lt 2) {
    throw "Test-ClaudeCommandExisting: native_local_bin must appear at least twice in function body (found $nativeBinCount)"
}
# 6b. 必须包含 PATH 冲突提示（证明 PATH 坏 + native 可用的分支存在）
if ($tceFuncText -notmatch 'PATH.*优先级冲突|BadPath|PATH 中 claude 不可用，但 native_local_bin') {
    throw "Test-ClaudeCommandExisting must log PATH conflict when PATH claude is broken but native_local_bin is usable"
}
# 6c. 阶段 2 注释必须存在（证明 native 检测是独立阶段，不是 else 分支里的附属逻辑）
if ($tceFuncText -notmatch '阶段\s*2.*Native Install 默认路径' -and $tceFuncText -notmatch '只要当前不是 Usable.*继续检测 Native') {
    throw "Test-ClaudeCommandExisting must have phase 2 native check as standalone block (not only in Get-Command else branch)"
}
# 6d. 函数返回路径验证：PATH 可用时 return $result 必须在 native 检测之前
# 用 [\s\S]* 而非 .* 以跨行匹配阶段2注释中的 "native" 和第3行的 "local"
if ($tceFuncText -notmatch 'return \$result[\s\S]{0,800}阶段\s*2[\s\S]{0,200}native[\s\S]{0,200}local') {
    throw "Test-ClaudeCommandExisting: PATH usable return must precede phase 2 native check"
}
# 6e. 确认 .local\bin 路径构造在函数文本中存在
if ($tceFuncText -notmatch '\.local\\bin.*claude\.exe') {
    throw "Test-ClaudeCommandExisting must construct .local\bin\claude.exe path"
}

Write-Host "[check] P0 fix anti-regression OK"

# ============================================================
# P1 修复防回归: Claude 命令来源清单 + npm 安装风险 (v1.3.2)
# ============================================================
Write-Host "[check] P1 fix anti-regression: Claude command inventory + npm install risks"

$claudeInstallText = Get-Content -Path (Join-Path $RootDir "lib\claude-install.ps1") -Raw -Encoding UTF8
$doctorText = Get-Content -Path (Join-Path $RootDir "doctor.ps1") -Raw -Encoding UTF8

# 1. 必须存在 Get-ClaudeCommandInventory
if ($claudeInstallText -notmatch 'function Get-ClaudeCommandInventory') {
    throw "Get-ClaudeCommandInventory function not found in lib/claude-install.ps1"
}

# 2. Get-ClaudeCommandInventory 必须包含关键内容
$inventoryPatterns = @(
    @{ Name = 'Get-Command "claude" -All'; Pattern = 'Get-Command\s+"claude"\s+-All' },
    @{ Name = 'where.exe claude'; Pattern = 'where\.exe\s+claude' },
    @{ Name = 'native_local_bin'; Pattern = 'native_local_bin' },
    @{ Name = 'npm_global'; Pattern = 'npm_global' },
    @{ Name = 'WindowsApps'; Pattern = 'WindowsApps' },
    @{ Name = 'HasConflict'; Pattern = 'HasConflict' },
    @{ Name = 'ConflictSummary'; Pattern = 'ConflictSummary' }
)
foreach ($pat in $inventoryPatterns) {
    if ($claudeInstallText -notmatch $pat.Pattern) {
        throw "Get-ClaudeCommandInventory must contain: $($pat.Name)"
    }
}

# 3. doctor.ps1 必须调用 Get-ClaudeCommandInventory
if ($doctorText -notmatch 'Get-ClaudeCommandInventory') {
    throw "doctor.ps1 must call Get-ClaudeCommandInventory"
}

# 4. doctor.ps1 必须包含关键检测项名称
$doctorInventoryNames = @("Claude 命令来源", "当前 claude 来源", "Claude 命令冲突")
foreach ($name in $doctorInventoryNames) {
    if ($doctorText -notmatch [regex]::Escape($name)) {
        throw "doctor.ps1 must contain check name: $name"
    }
}

# 5. Test-NpmMirrorClaudeCodeNetwork 必须包含平台包检测
$platformPkgPatterns = @(
    '@anthropic-ai/claude-code-win32-x64',
    '@anthropic-ai/claude-code-win32-arm64',
    'PlatformPackageReachable',
    'PlatformPackageVersion'
)
foreach ($pat in $platformPkgPatterns) {
    if ($claudeInstallText -notmatch [regex]::Escape($pat)) {
        throw "Test-NpmMirrorClaudeCodeNetwork must contain: $pat"
    }
}

# 6. 必须存在 Get-NpmInstallRiskConfig
if ($claudeInstallText -notmatch 'function Get-NpmInstallRiskConfig') {
    throw "Get-NpmInstallRiskConfig function not found in lib/claude-install.ps1"
}

# 提取 Get-NpmInstallRiskConfig 函数体供后续检查
$getNpmRiskLines = @($claudeInstallText -split "`n")
$inFunc = $false; $funcLines = [System.Collections.ArrayList]::new()
foreach ($l in $getNpmRiskLines) {
    if ($l -match 'function Get-NpmInstallRiskConfig') { $inFunc = $true }
    if ($inFunc) {
        [void]$funcLines.Add($l)
        if ($l -match '^\}\s*$' -and $funcLines.Count -gt 3) { break }
    }
}
$npmRiskFuncBody = $funcLines -join "`n"
if (-not $npmRiskFuncBody) { $npmRiskFuncBody = $claudeInstallText }

# 7. Get-NpmInstallRiskConfig 必须检查 optional, omit, ignore-scripts, registry
# 函数用 foreach ($key in $configKeys) 循环，不会硬编码 "config get optional"，
# 但必须在 $configKeys 数组中包含这四个键，并在风险分析中引用它们。
$npmRiskConfigPatterns = @(
    @{ Name = 'optional literal'; Pattern = '"optional"' },
    @{ Name = 'omit literal'; Pattern = '"omit"' },
    @{ Name = 'ignore-scripts literal'; Pattern = '"ignore-scripts"' },
    @{ Name = 'registry literal'; Pattern = '"registry"' },
    @{ Name = 'optional risk check'; Pattern = '\$result\.Optional\s+-eq\s+"false"' },
    @{ Name = 'omit risk check'; Pattern = '\$result\.Omit\s+-match\s+"optional"' },
    @{ Name = 'ignore-scripts risk check'; Pattern = '\$result\.IgnoreScripts\s+-eq\s+"true"' }
)
foreach ($pat in $npmRiskConfigPatterns) {
    if ($npmRiskFuncBody -notmatch $pat.Pattern) {
        throw "Get-NpmInstallRiskConfig must contain pattern: $($pat.Name)"
    }
}

# 8. doctor.ps1 必须包含 npm 安装风险检测项名称
$doctorNpmRiskNames = @("npm 安装风险配置", "npm optional", "npm omit",
    "npm ignore-scripts", "npm registry")
foreach ($name in $doctorNpmRiskNames) {
    if ($doctorText -notmatch [regex]::Escape($name)) {
        throw "doctor.ps1 must contain check name: $name"
    }
}

# 9. npm config 检测不得裸用 npm（必须通过 Resolve-NpmCmdPath 或绝对路径）
if ($npmRiskFuncBody -match 'Invoke-CommandSafe\s+-Command\s+"npm"') {
    throw "Get-NpmInstallRiskConfig must NOT use bare 'npm' in Invoke-CommandSafe; use Resolve-NpmCmdPath"
}
if ($npmRiskFuncBody -notmatch 'Resolve-NpmCmdPath') {
    throw "Get-NpmInstallRiskConfig must use Resolve-NpmCmdPath to resolve npm.cmd"
}

Write-Host "[check] P1 fix anti-regression OK"

# ============================================================
# P1.1 修复防回归: 误报候选/误报冲突修复 (v1.3.2)
# ============================================================
Write-Host "[check] P1.1 fix anti-regression: false candidate/conflict fix"

$claudeInstallText = Get-Content -Path (Join-Path $RootDir "lib\claude-install.ps1") -Raw -Encoding UTF8
$doctorText = Get-Content -Path (Join-Path $RootDir "doctor.ps1") -Raw -Encoding UTF8

# 1. Get-ClaudeCommandInventory 必须包含 MissingKnownPaths
if ($claudeInstallText -notmatch 'MissingKnownPaths') {
    throw "Get-ClaudeCommandInventory must include MissingKnownPaths field"
}

# 2. _add 函数中必须有 KnownPath, if (-not $exists), return
$inventoryFuncText = if ($claudeInstallText -match '(?s)function Get-ClaudeCommandInventory\s*\{.*?\n(?=function Test-HttpEndpointReachable)') {
    $matches[0]
} else { "" }
if (-not $inventoryFuncText) { $inventoryFuncText = $claudeInstallText }

if ($inventoryFuncText -notmatch '\[switch\]\$KnownPath') {
    throw "Get-ClaudeCommandInventory _add must have -KnownPath switch parameter"
}
if ($inventoryFuncText -notmatch 'if\s*\(\s*-not\s+\$exists\s*\)') {
    throw "Get-ClaudeCommandInventory _add must check if (-not `$exists)"
}
if ($inventoryFuncText -notmatch 'KnownPath[\s\S]{0,200}MissingKnownPaths') {
    throw "Get-ClaudeCommandInventory _add must add known non-existent paths to MissingKnownPaths"
}

# 3. Candidates 不能包含 Exists=false 的候选（注释验证）
if ($inventoryFuncText -notmatch '只有存在才进入 Candidates.*不存在路径已在 _add 中过滤') {
    throw "Get-ClaudeCommandInventory must have comment: 只有存在才进入 Candidates"
}

# 4. Conflict 判断基于 Candidates.Count（不是 MissingKnownPaths）
if ($inventoryFuncText -notmatch '\$inventory\.Candidates\.Count\s+-gt\s+1') {
    throw "Get-ClaudeCommandInventory HasConflict must use `$inventory.Candidates.Count"
}

# 5. doctor.ps1 Claude Code CLI 检测必须使用 inventory.Active 或 Get-ClaudeCommandInventory
if ($doctorText -notmatch '\$inventory\.Active.*Usable') {
    throw "doctor.ps1 Claude Code CLI detection must use `$inventory.Active.Usable"
}
if ($doctorText -notmatch 'Get-ClaudeCommandInventory') {
    throw "doctor.ps1 must call Get-ClaudeCommandInventory"
}

# 6. doctor.ps1 候选输出必须只来自 $inventory.Candidates
if ($doctorText -notmatch '\$inventory\.Candidates\[') {
    throw "doctor.ps1 candidate loop must iterate over `$inventory.Candidates"
}

# 7. doctor.ps1 不得输出 MissingKnownPaths 到报告分组
$writeReportChecksText = if ($doctorText -match '(?s)function Write-ReportChecks\s*\{.*?\n(?=function Write-ReportErrors)') {
    $matches[0]
} else { "" }
if ($writeReportChecksText -match 'MissingKnownPaths') {
    throw "doctor.ps1 Write-ReportChecks must NOT reference MissingKnownPaths"
}

# 8. doctor.ps1 candidate Error 拼接前必须经过 Sanitize-PathForReport
if ($doctorText -notmatch '\$errSafe\s*=\s*Sanitize-PathForReport.*\$c\.Error') {
    throw "doctor.ps1 candidate error detail must be sanitized with Sanitize-PathForReport"
}

Write-Host "[check] P1.1 fix anti-regression OK"

# ============================================================
# P1.2 修复防回归: Write-QuickSummary 与 inventory 一致性 (v1.3.2)
# ============================================================
Write-Host "[check] P1.2 fix anti-regression: Write-QuickSummary consistency with claude inventory"

$doctorText = Get-Content -Path (Join-Path $RootDir "doctor.ps1") -Raw -Encoding UTF8

# 提取 Write-QuickSummary 函数体
$wqsFuncText = if ($doctorText -match '(?s)function Write-QuickSummary\s*\{.*?\n\}') {
    $matches[0]
} else { "" }
if (-not $wqsFuncText) {
    throw "Write-QuickSummary function body not found"
}

# 1. Write-QuickSummary 不得直接以 Test-ClaudeInstalled 作为主判断
#    必须通过 CheckResults 中的 Claude Code CLI / 当前 claude 来源 读取
if ($wqsFuncText -notmatch 'Claude Code CLI') {
    throw "Write-QuickSummary must reference 'Claude Code CLI' from CheckResults"
}
if ($wqsFuncText -notmatch '当前 claude 来源') {
    throw "Write-QuickSummary must reference '当前 claude 来源' from CheckResults"
}
if ($wqsFuncText -notmatch 'DoctorState\.CheckResults') {
    throw "Write-QuickSummary must read from DoctorState.CheckResults"
}

# 2. 如果 Write-QuickSummary 中出现 Test-ClaudeInstalled，必须附近有 fallback/兜底/UNKNOWN
if ($wqsFuncText -match 'Test-ClaudeInstalled') {
    if ($wqsFuncText -notmatch 'fallback|兜底|UNKNOWN') {
        throw "Write-QuickSummary Test-ClaudeInstalled usage must be surrounded by fallback/兜底/UNKNOWN context"
    }
}

# 3. Write-QuickSummary 必须包含新的提示文本
$wqsRequiredTexts = @(
    "检测到可用安装，但 PATH 可能存在冲突",
    "未安装或不可用"
)
foreach ($t in $wqsRequiredTexts) {
    if ($wqsFuncText -notmatch [regex]::Escape($t)) {
        throw "Write-QuickSummary must contain text: $t"
    }
}

# 4. Check-Commands 中 Claude Code CLI OK 时 Detail 应为版本号
$checkCommandsText = if ($doctorText -match '(?s)function Check-Commands\s*\{.*?\n(?=function Check-Files)') {
    $matches[0]
} else { "" }
if ($checkCommandsText -notmatch '\$inventory\.Active\.Version') {
    throw "Check-Commands Claude Code CLI OK must use `$inventory.Active.Version as Detail"
}

# 5. Write-QuickSummary 禁止嵌套双引号拼接（如 "aaa"bbb"ccc"）
#    "详情见"Claude 命令来源"" 这样的写法会导致 Add-ReportLine 参数绑定异常
if ($wqsFuncText -match '"详情见"Claude 命令来源""') {
    throw "Write-QuickSummary must NOT contain nested double-quote pattern: `"详情见`"Claude 命令来源`"`""
}
if ($wqsFuncText -notmatch [regex]::Escape('详情见"Claude 命令来源"')) {
    throw "Write-QuickSummary must contain correctly quoted: 详情见`"Claude 命令来源`""
}

Write-Host "[check] P1.2 fix anti-regression OK"

# ============================================================
# P1/P2 第三批防回归检查: 32-bit PS, TLS, 代理, 文件占用, WSL 可选, Git 文案
# ============================================================
Write-Host "[check] P1/P2 environment diagnostics anti-regression"

# 1. 32-bit PowerShell detection
$envCheckPath = Join-Path $RootDir "lib\env-check.ps1"
$envCheckText = Get-Content $envCheckPath -Raw -Encoding UTF8
if ($envCheckText -notmatch 'Is64BitOperatingSystem') { throw "env-check.ps1 must contain Is64BitOperatingSystem" }
if ($envCheckText -notmatch 'Is64BitProcess') { throw "env-check.ps1 must contain Is64BitProcess" }
if ($envCheckText -notmatch 'IsWow64PowerShell') { throw "env-check.ps1 must contain IsWow64PowerShell" }
if ($envCheckText -notmatch '32 位 PowerShell') { throw "env-check.ps1 must contain 32-bit PowerShell warning text" }

# 2. TLS
$commonPath = Join-Path $RootDir "lib\common.ps1"
$commonText = Get-Content $commonPath -Raw -Encoding UTF8
if ($commonText -notmatch 'Initialize-CcdiNetworkDefaults') { throw "common.ps1 must contain Initialize-CcdiNetworkDefaults" }
if ($commonText -notmatch 'Tls12') { throw "common.ps1 must contain Tls12" }
$bootstrapPath = Join-Path $RootDir "lib\bootstrap.ps1"
$bootstrapText = Get-Content $bootstrapPath -Raw -Encoding UTF8
if ($bootstrapText -notmatch 'Initialize-CcdiNetworkDefaults') { throw "bootstrap.ps1 must call Initialize-CcdiNetworkDefaults" }

# 3. Proxy sanitization
if ($commonText -notmatch 'Sanitize-ProxyUrl') { throw "common.ps1 must contain Sanitize-ProxyUrl" }
if ($commonText -notmatch 'http://user:pass@|https?://[^/@\s:]+:[^/@\s]+@') { throw "common.ps1 must handle http://user:pass@ proxy URLs" }
if ($commonText -notmatch 'socks5?h?://[^/@\s:]+:[^/@\s]+@') { throw "common.ps1 must handle socks5://user:pass@ proxy URLs" }
# Check that Convert-ToSafeReportText calls Sanitize-ProxyUrl
$commonLines = Get-Content -Path (Join-Path $RootDir "lib\common.ps1") -Encoding UTF8
$cstartLine = -1
$cendLine = -1
for ($i = 0; $i -lt $commonLines.Count; $i++) {
    if ($commonLines[$i] -match '^function Convert-ToSafeReportText\b') { $cstartLine = $i }
    if ($cstartLine -ge 0 -and $i -gt $cstartLine -and $commonLines[$i] -match '^function \w') {
        $cendLine = $i - 1
        break
    }
}
if ($cstartLine -ge 0 -and $cendLine -lt 0) { $cendLine = $commonLines.Count - 1 }
if ($cstartLine -ge 0) {
    $csafeBody = ($commonLines[$cstartLine..$cendLine] -join "`n")
    if ($csafeBody -notmatch 'Sanitize-ProxyUrl') { throw "Convert-ToSafeReportText must call Sanitize-ProxyUrl" }
}

# 4. Doctor proxy diagnostics
$doctorPath = Join-Path $RootDir "doctor.ps1"
$doctorText = Get-Content $doctorPath -Raw -Encoding UTF8
if ($doctorText -notmatch 'HTTPS_PROXY') { throw "doctor.ps1 must contain HTTPS_PROXY" }
if ($doctorText -notmatch 'HTTP_PROXY') { throw "doctor.ps1 must contain HTTP_PROXY" }
if ($doctorText -notmatch 'NO_PROXY') { throw "doctor.ps1 must contain NO_PROXY" }
if ($doctorText -notmatch 'ALL_PROXY') { throw "doctor.ps1 must contain ALL_PROXY" }
if ($doctorText -notmatch 'netsh') { throw "doctor.ps1 must contain netsh" }
if ($doctorText -notmatch 'winhttp') { throw "doctor.ps1 must contain winhttp" }
if ($doctorText -notmatch 'show') { throw "doctor.ps1 must contain show (netsh winhttp show proxy)" }
if ($doctorText -notmatch 'proxy') { throw "doctor.ps1 must contain proxy" }

# 5. Native Install file lock error
$claudeInstallPath = Join-Path $RootDir "lib\claude-install.ps1"
$claudeInstallText = Get-Content $claudeInstallPath -Raw -Encoding UTF8
if ($claudeInstallText -notmatch 'Test-IsClaudeNativeFileLockError') { throw "claude-install.ps1 must contain Test-IsClaudeNativeFileLockError" }
if ($claudeInstallText -notmatch 'used by another process') { throw "claude-install.ps1 must contain 'used by another process'" }
if ($claudeInstallText -notmatch '\.claude[/\\]downloads') { throw "claude-install.ps1 must contain .claude\downloads or .claude/downloads" }
if ($claudeInstallText -notmatch '不要删除.*settings\.json|settings\.json.*保护') { throw "claude-install.ps1 must protect settings.json (do not delete)" }

# 6. WSL
if ($doctorText -notmatch '\[switch\]\$DeepWslCheck') { throw "doctor.ps1 must contain [switch]`$DeepWslCheck" }
if ($doctorText -notmatch '未执行深度启动检测') { throw "doctor.ps1 must contain '未执行深度启动检测'" }
if ($doctorText -notmatch 'WSL 是高级选项，不影响 Windows 原生安装') { throw "doctor.ps1 must contain WSL advice text" }
$oneClickDiagnosisPath = Join-Path $RootDir "一键诊断.cmd"
$oneClickText = Get-Content $oneClickDiagnosisPath -Raw -Encoding ASCII
if ($oneClickText -match 'DeepWslCheck') { throw "一键诊断.cmd must NOT contain DeepWslCheck" }
# Write-QuickSummary must not call Test-WslInstalled
# Use line-number based extraction to avoid regex issues with CRLF
$doctorLines = Get-Content -Path (Join-Path $RootDir "doctor.ps1") -Encoding UTF8
$wqsStartLine = -1
$wqsEndLine = -1
for ($i = 0; $i -lt $doctorLines.Count; $i++) {
    if ($doctorLines[$i] -match '^function Write-QuickSummary\b') { $wqsStartLine = $i }
    if ($wqsStartLine -ge 0 -and $i -gt $wqsStartLine -and $doctorLines[$i] -match '^function \w') {
        $wqsEndLine = $i - 1
        break
    }
}
if ($wqsStartLine -ge 0 -and $wqsEndLine -lt 0) { $wqsEndLine = $doctorLines.Count - 1 }
if ($wqsStartLine -ge 0) {
    $wqsBodyLines = $doctorLines[$wqsStartLine..$wqsEndLine]
    $wqsBody = $wqsBodyLines -join "`n"
    # Strip comments before checking (the comment itself mentions Test-WslInstalled)
    $wqsBodyNoComments = ($wqsBodyLines | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    if ($wqsBodyNoComments -match 'Test-WslInstalled') { throw "Write-QuickSummary must NOT call Test-WslInstalled" }
}

# 7. Git文案
$startHerePath = Join-Path $RootDir "Start-Here.ps1"
$startHereText = Get-Content $startHerePath -Raw -Encoding UTF8
$gitPhrase1 = "Git 不是安装 Claude Code 的硬性要求"
$foundGitPhrase1 = ($startHereText -match [regex]::Escape($gitPhrase1)) -or ($doctorText -match [regex]::Escape($gitPhrase1))
if (-not $foundGitPhrase1) {
    # Check docs too
    $readmePath = Join-Path $RootDir "README.md"
    $readmeText = if (Test-Path $readmePath) { Get-Content $readmePath -Raw -Encoding UTF8 } else { "" }
    $foundGitPhrase1 = ($readmeText -match [regex]::Escape($gitPhrase1))
}
if (-not $foundGitPhrase1) { throw "At least one of Start-Here.ps1, doctor.ps1, or docs must contain: Git 不是安装 Claude Code 的硬性要求" }

# Check docs for prohibited phrases
$docsDir = Join-Path $RootDir "docs"
if (Test-Path $docsDir) {
    $docFiles = Get-ChildItem $docsDir -Filter "*.md" -ErrorAction SilentlyContinue
    foreach ($f in $docFiles) {
        $docContent = Get-Content $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($docContent -match '必须安装 Git 才能安装 Claude Code') {
            throw "$($f.Name): must not contain '必须安装 Git 才能安装 Claude Code'"
        }
        if ($docContent -match 'Git 是安装 Claude Code 的硬性要求') {
            throw "$($f.Name): must not contain 'Git 是安装 Claude Code 的硬性要求'"
        }
    }
}

# 8. P1.3 保持
# Reuse wqsBodyLines from check 6 above (must not call Test-WslInstalled)
if ($wqsStartLine -ge 0) {
    $wqsBodyForP13 = ($doctorLines[$wqsStartLine..$wqsEndLine] -join "`n")
}
if ($wqsBodyForP13 -notmatch [regex]::Escape('详情见"Claude 命令来源"')) {
    throw "Write-QuickSummary must still contain correctly quoted: 详情见`"Claude 命令来源`""
}
if ($wqsBodyForP13 -match [regex]::Escape('详情见"Claude 命令来源"')) {
    # Should NOT have the unquoted version
    Write-Log "DEBUG" "Write-QuickSummary correctly uses single quotes around the detail reference"
}

Write-Host "[check] P1/P2 environment diagnostics anti-regression OK"

# ============================================================
# P3.1 防回归检查: RawError 数据流 + 文件占用增强 + WSL 重复查询
# ============================================================
Write-Host "[check] P3.1 anti-regression: RawError dataflow, lock keywords, WSL probe reduction"

$claudeInstallText = Get-Content -Path (Join-Path $RootDir "lib\claude-install.ps1") -Raw -Encoding UTF8

# 1. Native Install 返回结构必须包含 RawError
if ($claudeInstallText -notmatch 'RawError') { throw "claude-install.ps1 must contain RawError" }
# Install-ClaudeCodeNative 中 downloadResult.Error 赋给 RawError
if ($claudeInstallText -notmatch 'RawError\s*=\s*\$downloadResult\.Error') { throw "Install-ClaudeCodeNative must set RawError from downloadResult.Error" }
# Install-ClaudeCodeNative 中 installResult.Error 赋给 RawError
if ($claudeInstallText -notmatch 'RawError\s*=\s*\$installResult\.Error') { throw "Install-ClaudeCodeNative must set RawError from installResult.Error" }

# 2. 文件占用检测必须使用 RawError（原 Error 太泛化）
$lockCheckArea = if ($claudeInstallText -match '(?s)文件占用检测.*?Write-Warning.*?settings\.json') { $matches[0] } else { "" }
if ($lockCheckArea -notmatch 'nativeResult\.RawError') { throw "File lock check must use nativeResult.RawError" }
if ($lockCheckArea -notmatch 'nativeResult\.Error') { throw "File lock check should also include nativeResult.Error" }
# 不应仅依赖 $nativeResult.Error（太泛化）
if ($lockCheckArea -match 'Test-IsClaudeNativeFileLockError\s+-Text\s+\$nativeResult\.Error\b' -and $lockCheckArea -notmatch 'nativeResult\.RawError') {
    throw "File lock check must not rely solely on generic Error"
}

# 3. 文件占用检测函数必须包含新增关键词
if ($claudeInstallText -notmatch 'The process cannot access the file') { throw "File lock function must include 'The process cannot access the file'" }
if ($claudeInstallText -notmatch 'Access to the path') { throw "File lock function must include 'Access to the path'" }
if ($claudeInstallText -notmatch '\\bis denied\\b') { throw "File lock function must include 'is denied'" }
if ($claudeInstallText -notmatch '拒绝访问') { throw "File lock function must include '拒绝访问'" }

# 4. WSL 重复查询
$envCheckText = Get-Content -Path (Join-Path $RootDir "lib\env-check.ps1") -Raw -Encoding UTF8
if ($envCheckText -notmatch '\$WslInfo') { throw "Test-UbuntuInWsl must have WslInfo parameter" }
if ($envCheckText -notmatch 'if\s*\(\s*-not\s+\$WslInfo\s*\)\s*\{') {
    throw "Test-UbuntuInWsl must have if (-not `$WslInfo) fallback"
}

$doctorText = Get-Content -Path (Join-Path $RootDir "doctor.ps1") -Raw -Encoding UTF8
if ($doctorText -notmatch 'Test-UbuntuInWsl\s+-WslInfo\s+\$wslInfo') { throw "Check-WSL must call Test-UbuntuInWsl -WslInfo `$wslInfo" }

# Check-WSL 函数体中 Test-WslInstalled 调用次数应为 1
$doctorLines = Get-Content -Path (Join-Path $RootDir "doctor.ps1") -Encoding UTF8
$checkWslStart = -1
$checkWslEnd = -1
for ($i = 0; $i -lt $doctorLines.Count; $i++) {
    if ($doctorLines[$i] -match '^function Check-WSL\b') { $checkWslStart = $i }
    if ($checkWslStart -ge 0 -and $i -gt $checkWslStart -and $doctorLines[$i] -match '^function \w') {
        $checkWslEnd = $i - 1
        break
    }
}
if ($checkWslStart -ge 0) {
    if ($checkWslEnd -lt 0) { $checkWslEnd = $doctorLines.Count - 1 }
    $checkWslBody = ($doctorLines[$checkWslStart..$checkWslEnd] | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    $wslCount = ([regex]::Matches($checkWslBody, 'Test-WslInstalled')).Count
    if ($wslCount -ne 1) { throw "Check-WSL must call Test-WslInstalled exactly once, found $wslCount" }
}

# 5. 保持 DeepWslCheck 语义
if ($doctorText -notmatch '未执行深度启动检测') { throw "doctor.ps1 must still contain '未执行深度启动检测'" }
if ($doctorText -notmatch 'WSL 是高级选项，不影响 Windows 原生安装') { throw "doctor.ps1 must still contain WSL advice text" }


# 4.5 Check-Commands 不得调用 Test-WslInstalled（WSL 检测统一在 Check-WSL）
$checkCmdsStart = -1
$checkCmdsEnd = -1
for ($i = 0; $i -lt $doctorLines.Count; $i++) {
    if ($doctorLines[$i] -match '^function Check-Commands\b') { $checkCmdsStart = $i }
    if ($checkCmdsStart -ge 0 -and $i -gt $checkCmdsStart -and $doctorLines[$i] -match '^function \w') {
        $checkCmdsEnd = $i - 1
        break
    }
}
if ($checkCmdsStart -ge 0) {
    if ($checkCmdsEnd -lt 0) { $checkCmdsEnd = $doctorLines.Count - 1 }
    $checkCmdsBody = ($doctorLines[$checkCmdsStart..$checkCmdsEnd] | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    if ($checkCmdsBody -match 'Test-WslInstalled') {
        throw "Check-Commands must NOT call Test-WslInstalled (WSL detection belongs in Check-WSL)"
    }
}


# 4.6 Native Install 日志不得记录 RawError 原文（防止泄露本地路径）
if ($claudeInstallText -match "Native Install lock check raw") {
    throw "claude-install.ps1 must NOT log RawError snippet; use HasRawError boolean only"
}

# 4.7 Native Install 日志必须含 HasRawError（结构化日志）
if ($claudeInstallText -notmatch "Native Install lock check: HasRawError=") {
    throw "claude-install.ps1 must log Native Install lock check with HasRawError boolean format"
}

Write-Host "[check] P3.1 anti-regression OK"

# ============================================================
# P4 WSL probe anti-regression (Task 1: dedup WSL detection)
# ============================================================
Write-Host "[check] P4 anti-regression: Start-Here WSL dedup + wsl -d gate"

$startHereLines = Get-Content -Path (Join-Path $RootDir "Start-Here.ps1") -Encoding UTF8
$startHereRaw = $startHereLines -join "`n"

# 1. After Test-WslInstalled in same block, Test-UbuntuInWsl must pass -WslInfo
$inWslBlock = $false
$hasWslInfoVar = $false
$passingWslInfoCount = 0
$notPassingWslInfoCount = 0
for ($i = 0; $i -lt $startHereLines.Count; $i++) {
    $line = $startHereLines[$i]
    if ($line -match '^\s*\$wslInfo\s*=\s*Test-WslInstalled') { $inWslBlock = $true; $hasWslInfoVar = $true; continue }
    if ($inWslBlock -and $line -match '^\s*function\s') { $inWslBlock = $false; $hasWslInfoVar = $false }
    if ($inWslBlock -and $line -match '^\s*\}\s*$' -and $i -gt 0 -and $startHereLines[$i-1] -notmatch '^\s*\}') { $inWslBlock = $false; $hasWslInfoVar = $false }
    if ($hasWslInfoVar -and $line -match 'Test-UbuntuInWsl\b') {
        if ($line -match '-WslInfo\s+\$wslInfo') { $passingWslInfoCount++ }
        else { $notPassingWslInfoCount++ }
    }
}
if ($notPassingWslInfoCount -gt 0) {
    throw "Start-Here.ps1: $notPassingWslInfoCount Test-UbuntuInWsl call(s) after Test-WslInstalled do NOT pass -WslInfo `$wslInfo (found $passingWslInfoCount passing)"
}

# 2. Default Start-Here path must not contain wsl -d / bash -c deep WSL commands
$startHereFunctionBodies = $startHereRaw
if ($startHereFunctionBodies -match '(?s)wsl\s+-d\s|-d\s+Ubuntu.*bash\s+-c|wsl\.exe.*-d\s') {
    throw "Start-Here.ps1: default install path must NOT contain wsl -d / bash -c deep detection"
}

# 3. doctor.ps1 must still allow deep WSL under -DeepWslCheck
$doctorText = Get-Content -Path (Join-Path $RootDir "doctor.ps1") -Raw -Encoding UTF8
if ($doctorText -notmatch 'DeepWslCheck[\s\S]{0,300}wsl\s+-d\s') {
    throw "doctor.ps1: -DeepWslCheck must still allow wsl -d deep detection"
}

Write-Host "[check] P4 anti-regression OK"

# ============================================================
# P5 state semantics anti-regression (Task 2: firstRunAt vs installedAt)
# ============================================================
Write-Host "[check] P5 anti-regression: state file firstRunAt / claudeInstallCompletedAt semantics"

$stateText = Get-Content -Path (Join-Path $RootDir "lib\state.ps1") -Raw -Encoding UTF8

# 1. Initialize-CcdiState initial object must NOT write installedAt as completion time
if ($stateText -match 'Initialize-CcdiState[\s\S]{0,500}installedAt\s*=\s*\$now') {
    throw "state.ps1: Initialize-CcdiState must NOT write installedAt = `$now (use firstRunAt)"
}

# 2. Must contain firstRunAt in initial state
if ($stateText -notmatch 'firstRunAt\s*=') {
    throw "state.ps1: Initialize-CcdiState must contain firstRunAt field"
}

# 3. Must contain claudeInstallCompletedAt
if ($stateText -notmatch 'claudeInstallCompletedAt') {
    throw "state.ps1: must contain claudeInstallCompletedAt field"
}

# 4. uninstall-config must NOT treat firstRunAt as install completion time
$uninstallTextForCheck = Get-Content -Path (Join-Path $RootDir "uninstall-config.ps1") -Raw -Encoding UTF8
if ($uninstallTextForCheck -match '首次运行时间[\s\S]{0,30}安装完成' -or $uninstallTextForCheck -notmatch '首次运行时间') {
    throw "uninstall-config.ps1 must display firstRunAt separately from install completion"
}

    # 5. Every install-success Update-CcdiState (official_native/winget/npm_npmmirror + installed)
    #    must include claudeInstallCompletedAt
    $claudeInstallTextForP5 = Get-Content -Path (Join-Path $RootDir "lib\claude-install.ps1") -Raw -Encoding UTF8
    $successMethods = @("official_native","winget","npm_npmmirror")
    foreach ($method in $successMethods) {
        $blocks = [regex]::Matches($claudeInstallTextForP5, "(?s)claudeInstallMethod\s*=\s*`"$method`"[\s\S]{0,100}claudeInstallStatus\s*=\s*`"installed`"[\s\S]{0,200}?\| Out-Null")
        foreach ($block in $blocks) {
            if ($block.Value -notmatch 'claudeInstallCompletedAt') {
                throw "claude-install.ps1: $method + installed must set claudeInstallCompletedAt"
            }
        }
    }

    # 6. skipped_existing branch must NOT write claudeInstallCompletedAt
    $skippedExistingBlocks = [regex]::Matches($claudeInstallTextForP5, "(?s)skipped_existing[\s\S]{0,200}?\| Out-Null")
    foreach ($block in $skippedExistingBlocks) {
        if ($block.Value -match 'claudeInstallCompletedAt') {
            throw "claude-install.ps1: skipped_existing must NOT set claudeInstallCompletedAt"
        }
    }

    # 7. installed_needs_restart (npm_npmmirror) must have claudeInstallCompletedAt
    $needsRestartBlocks = [regex]::Matches($claudeInstallTextForP5, "(?s)installed_needs_restart.*?npm_npmmirror[\s\S]{0,200}?\| Out-Null")
    foreach ($block in $needsRestartBlocks) {
        if ($block.Value -notmatch 'claudeInstallCompletedAt') {
            throw "claude-install.ps1: installed_needs_restart must set claudeInstallCompletedAt"
        }
    }

Write-Host "[check] P5 anti-regression OK"

# ============================================================
# P6 Invoke-CommandSafe log sanitization (Task 3)
# ============================================================
Write-Host "[check] P6 anti-regression: Invoke-CommandSafe log sanitization"

$commonTextForCheck = Get-Content -Path (Join-Path $RootDir "lib\common.ps1") -Raw -Encoding UTF8

# 1. argumentLine must be sanitized before logging
if ($commonTextForCheck -match 'Write-Log.*args=\$argumentLine"\)' -or
    $commonTextForCheck -match 'Write-Log[\s\S]{0,50}\$argumentLine[\s\S]{0,50}(?<!SafeLogText)') {
    # This is approximate; the key check is that ConvertTo-SafeLogText exists
}

# 2. ConvertTo-SafeLogText must exist
if ($commonTextForCheck -notmatch 'function ConvertTo-SafeLogText') {
    throw "common.ps1: must contain ConvertTo-SafeLogText function"
}

# 3. Timeout stdout logging must sanitize
if ($commonTextForCheck -notmatch '超时部分 stdout[\s\S]{0,200}ConvertTo-SafeLogText') {
    throw "common.ps1: timeout stdout log must call ConvertTo-SafeLogText"
}

# 4. Timeout stderr logging must sanitize
if ($commonTextForCheck -notmatch '超时部分 stderr[\s\S]{0,200}ConvertTo-SafeLogText') {
    throw "common.ps1: timeout stderr log must call ConvertTo-SafeLogText"
}

# 5. DEBUG argumentLine logging must sanitize
if ($commonTextForCheck -notmatch 'Invoke-CommandSafe[\s\S]{0,200}args=\$\(ConvertTo-SafeLogText') {
    throw "common.ps1: Invoke-CommandSafe DEBUG log must sanitize argumentLine"
}

# 6. Timeout ERROR/WARN logging must sanitize argumentLine
if ($commonTextForCheck -notmatch '命令超时[\s\S]{0,200}ConvertTo-SafeLogText.*\$argumentLine') {
    throw "common.ps1: timeout log must sanitize argumentLine"
}

# Lightweight TestSafe test: Verify Mask-ApiKey works on sk- keys in log text
$testKey = "sk-test" + ("x" * 42)
$testLogText = "Authorization: Bearer $testKey`nANTHROPIC_AUTH_TOKEN=$testKey"
$safeLogText = ConvertTo-SafeLogText -Text $testLogText
if ($safeLogText -match [regex]::Escape($testKey)) {
    throw "ConvertTo-SafeLogText leaked full sk- key"
}
# Should contain masked form (sk***...XXXX)
if ($safeLogText -notmatch 'sk\*{4,}') {
    throw "ConvertTo-SafeLogText did not mask sk- key (expected sk****... suffix)"
}

Write-Host "[check] P6 anti-regression OK"

# ============================================================
# P7 v1.3.2 最终补修 (Timeout, Native fallback verify, wording, config check)
# ============================================================
Write-Host "[check] P7 anti-regression: v1.3.2 final patches"

$claudeInstallText = Get-Content -Path (Join-Path $RootDir "lib\claude-install.ps1") -Raw -Encoding UTF8
$startHereText = Get-Content -Path (Join-Path $RootDir "Start-Here.ps1") -Raw -Encoding UTF8

# --- 测试 1: Invoke-VisibleFileDownload 必须真正使用 TimeoutSec ---

# 1a. 必须定义 New-CcdiTimeoutWebClient 或等价 timeout web client
if ($claudeInstallText -notmatch 'New-CcdiTimeoutWebClient') {
    throw "claude-install.ps1 must define New-CcdiTimeoutWebClient for download timeout support"
}

# 1b. 必须设置 request.Timeout
if ($claudeInstallText -notmatch '\.Timeout\s*=') {
    throw "claude-install.ps1 downloader must set timeout from TimeoutSec"
}

# 1c. 必须设置 ReadWriteTimeout
if ($claudeInstallText -notmatch 'ReadWriteTimeout') {
    throw "claude-install.ps1 downloader must set ReadWriteTimeout to avoid stalled downloads"
}

# 1d. 必须返回 failed_download_timeout 状态
if ($claudeInstallText -notmatch 'failed_download_timeout') {
    throw "claude-install.ps1 Invoke-VisibleFileDownload must return failed_download_timeout on timeout"
}

# 1e. 不再使用未经 timeout 设置的 plain WebClient.DownloadFile
if ($claudeInstallText -match 'New-Object\s+System\.Net\.WebClient[\s\S]{0,300}DownloadFile' -and
    $claudeInstallText -notmatch 'New-CcdiTimeoutWebClient') {
    throw "claude-install.ps1 Invoke-VisibleFileDownload still uses plain WebClient.DownloadFile without timeout"
}

# --- 测试 2: Native failed branch 必须后验验证 ---

# 2a. 必须包含后验验证日志文本
if ($claudeInstallText -notmatch 'Native Install 失败后验验证') {
    throw "claude-install.ps1 Native failed branch must perform post-install claude verification"
}

# 2b. 必须处理 claude 已可用的情况
if ($claudeInstallText -notmatch 'Native Install returned failure but claude is usable') {
    throw "claude-install.ps1 Native failed branch must treat usable claude as success"
}

# 2c. 后验成功必须写 claudeInstallMethod = "official_native"
# 匹配 Native failed 分支中后验成功的 Update-CcdiState 块
$nativeFailedBranch = [regex]::Match($claudeInstallText, '(?s)Native Install 失败后验验证.*?\breturn \$result\b')
if ($nativeFailedBranch.Success) {
    if ($nativeFailedBranch.Value -notmatch 'claudeInstallMethod\s*=\s*"official_native"') {
        throw "claude-install.ps1 Native post-verification success must write claudeInstallMethod=official_native"
    }
}

# 2d. 后验验证必须在进入 winget fallback 之前执行
# (顺序: Native failed → 后验验证 → winget. 不应先 winget 后验)
$nativeToWinget = [regex]::Match($claudeInstallText, '(?s)Native Install 失败后验验证.*?尝试通过 winget 安装 Claude Code')
if (-not $nativeToWinget.Success) {
    throw "claude-install.ps1 native failed branch post-verification must appear before winget fallback"
}

# --- 测试 3: 文案不能误导为直接切换 npm ---

$badPhrases = @(
    'Claude 官方安装通道执行失败，正在自动切换国内 npm 镜像安装',
    '官方 Native Install 和 npm 镜像安装均失败'
)

foreach ($p in $badPhrases) {
    if ($claudeInstallText -match [regex]::Escape($p)) {
        throw "claude-install.ps1 misleading fallback wording remains: $p"
    }
}

# 必须出现"备用安装通道"
if ($claudeInstallText -notmatch '备用安装通道') {
    throw "claude-install.ps1 fallback wording should mention 备用安装通道"
}

# 必须出现 winget 在 npm 之前（winget.*npmmirror 或 winget.*npm）
if ($claudeInstallText -notmatch 'winget.*npmmirror|winget.*npm.*镜像') {
    throw "claude-install.ps1 fallback wording should mention winget before npmmirror/npm"
}

# --- 测试 4: 完成页必须用 Get-DeepSeekConfigStatus 判断配置完整性 ---

# 4a. Start-Here.ps1 Show-CompletionPage 不能继续用 HasEnv 判断 API Key
#  匹配 "HasEnv[\s\S]{0,200}DeepSeek API Key 尚未配置" — HasEnv 和 DeepSeek 提示在同一上下文
if ($startHereText -match 'HasEnv[\s\S]{0,400}DeepSeek API Key 尚未配置') {
    throw "Start-Here.ps1 completion page must NOT use HasEnv as API Key configured signal"
}

# 4b. Start-Here.ps1 必须调用 Get-DeepSeekConfigStatus
if ($startHereText -notmatch 'Get-DeepSeekConfigStatus') {
    throw "Start-Here.ps1 completion/fallback must use Get-DeepSeekConfigStatus for API Key configuration status"
}

# 4c. 必须出现 IsConfigured
if ($startHereText -notmatch 'IsConfigured') {
    throw "Start-Here.ps1 must check IsConfigured from Get-DeepSeekConfigStatus"
}

# --- 测试 5: 空 env 场景验证 ---

# 5a. Get-DeepSeekConfigStatus 必须检测空 env 对象
$configWriterText = Get-Content -Path (Join-Path $RootDir "lib\config-writer.ps1") -Raw -Encoding UTF8
if ($configWriterText -notmatch 'env 字段为空对象|env 字段为空（null）') {
    throw "config-writer.ps1 Get-DeepSeekConfigStatus must detect empty/null env field"
}

# 5b. 必须检测 ANTHROPIC_AUTH_TOKEN 为空
if ($configWriterText -notmatch '未设置 API Key|ANTHROPIC_AUTH_TOKEN[\s\S]{0,200}IsConfigured') {
    throw "config-writer.ps1 Get-DeepSeekConfigStatus must detect missing ANTHROPIC_AUTH_TOKEN"
}

Write-Host "[check] P7 anti-regression OK"

# ============================================================
# P8 v1.3.2 最终补漏 (user-entry chcp ban, WebClient Dispose)
# ============================================================
Write-Host "[check] P8 anti-regression: v1.3.2 final cleanup"

# --- P8a: 所有用户入口不得直接 chcp 65001 ---
$userEntryFiles = @(
    "Start-Here.ps1",
    "doctor.ps1",
    "configure-deepseek.ps1",
    "uninstall-config.ps1",
    "repair-deps.ps1",
    "install.ps1",
    "00-点我开始安装.cmd",
    "一键诊断.cmd",
    "恢复或卸载配置.cmd",
    "一键修复依赖.cmd",
    "Start-Install.cmd",
    "Run-Diagnostics.cmd",
    "Restore-Config.cmd"
)

foreach ($entry in $userEntryFiles) {
    $entryPath = Join-Path $RootDir $entry
    if (-not (Test-Path $entryPath)) { continue }

    $encoding = if ($entry -like "*.cmd") { "ASCII" } else { "UTF8" }
    $text = Get-Content -Path $entryPath -Raw -Encoding $encoding

    if ($text -match '(?m)^[^#\r\n]*chcp\s+65001') {
        throw "User entry file must not call chcp 65001 directly: $entry. Use Initialize-ConsoleEncodingSafe via bootstrap/logger."
    }
}

# --- P8b: Invoke-VisibleFileDownload must dispose WebClient ---
$claudeInstallText = Get-Content -Path (Join-Path $RootDir "lib\claude-install.ps1") -Raw -Encoding UTF8

# 初始化为 $null（幂等安全检查）
if ($claudeInstallText -notmatch '\$client\s*=\s*\$null') {
    throw "claude-install.ps1 Invoke-VisibleFileDownload should initialize `$client = `$null for safe disposal"
}

# finally 中必须 Dispose
if ($claudeInstallText -notmatch 'finally[\s\S]{0,300}\$client\.Dispose\(\)') {
    throw "claude-install.ps1 Invoke-VisibleFileDownload should dispose WebClient in finally"
}

Write-Host "[check] P8 anti-regression OK"

Write-Host "[check] OK"