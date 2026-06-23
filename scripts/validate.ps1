# ============================================================
# scripts/validate.ps1 - unified validation entry
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Smoke
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Full
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Release
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Hardcore
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode All
#
# Notes:
#   This script only orchestrates existing validation tools.
#   Flows that write Claude config must use CCDI_TEST_MODE + CCDI_TEST_USERPROFILE.
#
# Mode coverage (v1.3.2):
#   Smoke:    git diff --check + check.ps1 (PS 5.1 + pwsh)
#   Full:     Smoke + AST parse + ux-check.ps1 + install-decision-matrix.ps1 + Core sandbox
#   Release:  package-release.ps1 + simulate-user-release.ps1 + sandbox-full-user-simulation.ps1 + windows-scenario-matrix.ps1 (-Quick)
#   Hardcore: claude-failure-catalog.ps1 + hardcore-scenario-matrix.ps1 + doctor-repair-matrix.ps1 + check.ps1
#   All:      Full + Release + Hardcore + real settings.json unchanged check
# ============================================================

param(
    [ValidateSet("Smoke", "Full", "Release", "Hardcore", "All")]
    [string]$Mode = "Smoke",

    [string]$Version = "1.3.3",

    [switch]$SkipPwsh,

    [switch]$RequireClean,

    [switch]$TestForceFailure,

    [switch]$TestForcePreflightFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 显式导入核心模块（部分环境的模块自动加载不可用）
Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue

$RootDir = Split-Path -Parent $PSScriptRoot
$script:RootDir = $RootDir
Set-Location $RootDir

$script:StepCount = 0
$script:Failures = New-Object System.Collections.ArrayList

# 全局 TestSafe 模式：validate.ps1 只做验收，绝不真实安装/联网/WSL
$script:OldTestMode = $env:CCDI_TEST_MODE
$script:OldArtifactRoot = $env:CCDI_TEST_ARTIFACT_ROOT
$env:CCDI_TEST_MODE = "1"
$runStamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$script:RunRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ccdi-validate-$runStamp-" + [Guid]::NewGuid().ToString("N"))
$env:CCDI_TEST_ARTIFACT_ROOT = $script:RunRoot
foreach ($childDir in @("logs", "reports", "doctor", "children", "backup", "sandbox")) {
    New-Item -ItemType Directory -Path (Join-Path $script:RunRoot $childDir) -Force | Out-Null
}
Write-Host "[validate] Validation artifact root: $script:RunRoot"

# RequireClean 逻辑
$requireCleanForRun = $RequireClean -or ($Mode -eq "All")

function Write-ValidationHeader {
    param([string]$Title)

    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
}

function Get-RealSettingsSnapshot {
    $path = Join-Path ([System.Environment]::GetFolderPath("UserProfile")) ".claude\settings.json"
    if (-not (Test-Path $path)) {
        return [PSCustomObject]@{
            Path          = $path
            Exists        = $false
            Length        = $null
            SHA256        = $null
            LastWriteTime = $null
        }
    }

    $item = Get-Item $path
    return [PSCustomObject]@{
        Path          = $path
        Exists        = $true
        Length        = $item.Length
        SHA256        = (Get-FileHash -Algorithm SHA256 -Path $path).Hash
        LastWriteTime = $item.LastWriteTime
    }
}

function Backup-RealSettings {
    <#
    .SYNOPSIS
        备份真实 settings.json 到 TEMP 目录下的带时间戳文件。
        所有 sandbox 测试运行前调用，防止测试污染真实配置。
    .RETURNS
        包含 BackupPath 的哈希表，如果备份失败则为 $null。
    #>
    $path = Join-Path ([System.Environment]::GetFolderPath("UserProfile")) ".claude\settings.json"
    if (-not (Test-Path $path)) {
        Write-Host "[validate] Real settings.json does not exist, skip backup" -ForegroundColor DarkGray
        return $null
    }

    try {
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
        $backupDir = Join-Path $script:RunRoot "backup"
        if (-not (Test-Path $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }
        $backupPath = Join-Path $backupDir "validate-preflight-$timestamp.settings.json.bak"
        Copy-Item $path $backupPath -Force
        Write-Host "[validate] Real settings.json backed up: $backupPath" -ForegroundColor Green
        return @{
            BackupPath = $backupPath
            SHA256     = (Get-FileHash -Algorithm SHA256 -Path $path).Hash
            Length     = (Get-Item $path).Length
        }
    }
    catch {
        Write-Host "[validate] WARNING: Failed to backup real settings.json: $_" -ForegroundColor Yellow
        return $null
    }
}

function Restore-RealSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupPath,
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    if (-not (Test-Path $BackupPath)) {
        throw "Backup file not found: $BackupPath"
    }

    Copy-Item $BackupPath $TargetPath -Force
    Write-Host "[validate] Real settings.json restored from: $BackupPath" -ForegroundColor Green
}

function Assert-RealSettingsUnchanged {
    param(
        [Parameter(Mandatory = $true)]
        $Before,
        [Parameter(Mandatory = $true)]
        $After
    )

    if ($Before.Exists -ne $After.Exists -or $Before.Length -ne $After.Length -or $Before.SHA256 -ne $After.SHA256) {
        throw "Real settings.json changed. Before Exists=$($Before.Exists) Length=$($Before.Length) SHA256=$($Before.SHA256); After Exists=$($After.Exists) Length=$($After.Length) SHA256=$($After.SHA256)"
    }
}

function Invoke-ValidationStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $script:StepCount++
    $script:LastStepSucceeded = $false
    Write-Host ""
    Write-Host ("[validate] {0}. {1}" -f $script:StepCount, $Name) -ForegroundColor Cyan
    $started = Get-Date

    try {
        & $ScriptBlock
        $script:LastStepSucceeded = $true
        $elapsed = [int]((Get-Date) - $started).TotalSeconds
        Write-Host ("[validate] OK: {0} ({1}s)" -f $Name, $elapsed) -ForegroundColor Green
    }
    catch {
        $elapsed = [int]((Get-Date) - $started).TotalSeconds
        $message = "[validate] FAIL: $Name (${elapsed}s) - $($_.Exception.Message)"
        Write-Host $message -ForegroundColor Red
        [void]$script:Failures.Add($message)
    }
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [string[]]$Arguments = @()
    )

    & $FileName @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FileName $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function ConvertTo-WindowsCommandLineArgument {
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

function Invoke-PowerShellScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @(),

        [int]$TimeoutSec = 300,

        [string]$PowerShellExecutable = 'powershell.exe'
    )

    $safeFilePath = [System.IO.Path]::GetFullPath($FilePath)

    # Build the powershell.exe argument list using safe argument escaping
    $psArgsList = New-Object System.Collections.ArrayList
    [void]$psArgsList.Add("-NoProfile")
    [void]$psArgsList.Add("-ExecutionPolicy")
    [void]$psArgsList.Add("Bypass")
    [void]$psArgsList.Add("-File")
    [void]$psArgsList.Add($safeFilePath)

    foreach ($a in $Arguments) {
        [void]$psArgsList.Add($a)
    }

    $quotedParts = @()
    foreach ($arg in $psArgsList) {
        $quotedParts += ConvertTo-WindowsCommandLineArgument -Argument $arg
    }
    $cliArgs = $quotedParts -join " "
    $displayCommand = if ($Arguments.Count -gt 0) { "$safeFilePath $($Arguments -join ' ')" } else { $safeFilePath }

    # Determine report output paths
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($safeFilePath)
    $reportsDir = Join-Path $script:RunRoot "children"
    if (-not (Test-Path $reportsDir)) {
        New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
    }
    $childId = [Guid]::NewGuid().ToString("N")
    $stdoutFile = Join-Path $reportsDir "validate-child-${timestamp}-${scriptName}-${childId}.stdout.txt"
    $stderrFile = Join-Path $reportsDir "validate-child-${timestamp}-${scriptName}-${childId}.stderr.txt"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PowerShellExecutable
    $psi.Arguments = $cliArgs
    $psi.WorkingDirectory = $RootDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = [System.Diagnostics.Process]::Start($psi)

    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    $finished = $proc.WaitForExit($TimeoutSec * 1000)

    if (-not $finished) {
        # Timed out: capture partial output, then kill process tree
        try {
            $partialStdout = if ($stdoutTask.IsCompleted) { $stdoutTask.Result } else { "" }
            $partialStderr = if ($stderrTask.IsCompleted) { $stderrTask.Result } else { "" }
            if ($partialStdout) { [System.IO.File]::WriteAllText($stdoutFile, $partialStdout, (New-Object System.Text.UTF8Encoding($false))) }
            if ($partialStderr) { [System.IO.File]::WriteAllText($stderrFile, $partialStderr, (New-Object System.Text.UTF8Encoding($false))) }
        }
        catch { }

        $realPid = $proc.Id
        & taskkill.exe /PID $realPid /T /F 2>$null | Out-Null
        Start-Sleep -Milliseconds 500
        if (-not $proc.HasExited) { Stop-Process -Id $realPid -Force -ErrorAction SilentlyContinue }
        throw "TIMEOUT: $displayCommand (${TimeoutSec}s)`n  stdout: $stdoutFile`n  stderr: $stderrFile"
    }

    [void]$stdoutTask.Wait(5000)
    [void]$stderrTask.Wait(5000)

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exitCode = $proc.ExitCode

    # Always save stdout/stderr to files for diagnostics
    if ($stdout) {
        [System.IO.File]::WriteAllText($stdoutFile, $stdout, (New-Object System.Text.UTF8Encoding($false)))
    }
    if ($stderr) {
        [System.IO.File]::WriteAllText($stderrFile, $stderr, (New-Object System.Text.UTF8Encoding($false)))
    }

    # Clean up empty stdout/stderr files when everything passed
    if ($exitCode -eq 0) {
        if ((Test-Path $stdoutFile) -and (-not $stdout)) { Remove-Item $stdoutFile -Force -ErrorAction SilentlyContinue }
        if ((Test-Path $stderrFile) -and (-not $stderr)) { Remove-Item $stderrFile -Force -ErrorAction SilentlyContinue }
    }

    if ($exitCode -ne 0) {
        throw "$displayCommand failed with exit code $exitCode`n  stdout: $stdoutFile`n  stderr: $stderrFile"
    }
}

function Invoke-CoreSandboxFlow {
    $sandbox = Join-Path $script:RunRoot "sandbox\validate-core"
    $profile = Join-Path $sandbox "userprofile"
    $desktop = Join-Path $sandbox "desktop"

    $old = @{
        CCDI_TEST_MODE        = $env:CCDI_TEST_MODE
        CCDI_TEST_USERPROFILE = $env:CCDI_TEST_USERPROFILE
        CCDI_TEST_DESKTOP     = $env:CCDI_TEST_DESKTOP
        CCDI_API_KEY          = $env:CCDI_API_KEY
        CCDI_TEST_API_STATUS  = $env:CCDI_TEST_API_STATUS
    }

    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $profile, $desktop -Force | Out-Null

    try {
        $env:CCDI_TEST_MODE = "1"
        $env:CCDI_TEST_USERPROFILE = $profile
        $env:CCDI_TEST_DESKTOP = $desktop
        $env:CCDI_API_KEY = "sk-" + ("x" * 32)
        $env:CCDI_TEST_API_STATUS = "200"

        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "Start-Here.ps1") -Arguments @(
            "-NonInteractive", "-SkipDisclaimer", "-TestSafe"
        ) -TimeoutSec 300
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "Start-Here.ps1") -Arguments @("-FixDeps", "-TestSafe", "-NonInteractive") -TimeoutSec 300
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "doctor.ps1") -Arguments @(
            "-ShareSafe", "-SkipApiTest", "-NoOpenReport", "-TestSafe"
        ) -TimeoutSec 300

        $doctorRoot = Join-Path $script:RunRoot "doctor"
        foreach ($requiredDoctorFile in @("report.txt", "support-feedback.txt")) {
            $requiredPath = Join-Path $doctorRoot $requiredDoctorFile
            if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
                throw "Doctor test artifact missing: $requiredPath"
            }
        }
        $historyReports = @(Get-ChildItem -LiteralPath (Join-Path $doctorRoot "reports") -Filter "report-*.txt" -File -ErrorAction SilentlyContinue)
        if ($historyReports.Count -lt 1) {
            throw "Doctor history report missing under: $(Join-Path $doctorRoot 'reports')"
        }
    }
    finally {
        foreach ($name in $old.Keys) {
            if ($old[$name]) {
                Set-Item -Path "Env:\$name" -Value $old[$name]
            }
            else {
                Remove-Item -Path "Env:\$name" -ErrorAction SilentlyContinue
            }
        }
        Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ParseCheck {
    Get-ChildItem . -Filter "*.ps1" -Recurse |
        Where-Object { $_.FullName -notmatch '\\.git|\\.sandbox|\\backup|\\logs|\\reports|\\runs|\\release|\\node_modules' } |
        ForEach-Object {
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
            if ($errors.Count -gt 0) {
                throw "PowerShell parse failed: $($_.FullName) - $($errors[0].Message)"
            }
        }
}

function Invoke-SmokeValidation {
    Write-ValidationHeader "Smoke validation"

    Invoke-ValidationStep -Name "git diff --check" -ScriptBlock ([scriptblock]{
        Invoke-ExternalCommand -FileName "git" -Arguments @("diff", "--check")
    })
    Invoke-ValidationStep -Name "git diff --cached --check" -ScriptBlock ([scriptblock]{
        Invoke-ExternalCommand -FileName "git" -Arguments @("diff", "--cached", "--check")
    })
    Invoke-ValidationStep -Name "scripts/check.ps1 (Windows PowerShell)" -ScriptBlock ([scriptblock]{
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "scripts\check.ps1") -TimeoutSec 300
    })
    $pwshCommand = Get-Command "pwsh" -ErrorAction SilentlyContinue
    if ((-not $SkipPwsh) -and $pwshCommand) {
        Invoke-ValidationStep -Name "scripts/check.ps1 (pwsh)" -ScriptBlock ([scriptblock]{
            Invoke-PowerShellScript -PowerShellExecutable ([string]$pwshCommand.Source) -FilePath (Join-Path $RootDir "scripts\check.ps1") -TimeoutSec 300
        })
    }
}

function Invoke-FullValidation {
    Write-ValidationHeader "Full source validation"

    Invoke-SmokeValidation
    Invoke-ValidationStep -Name "scripts/test-vm-acceptance.ps1 (functional)" -ScriptBlock ([scriptblock]{
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "scripts\test-vm-acceptance.ps1") -TimeoutSec 300
    })
    Invoke-ValidationStep -Name "PowerShell full AST parse" -ScriptBlock ([scriptblock]{ Invoke-ParseCheck })
    Invoke-ValidationStep -Name "scripts/ux-check.ps1" -ScriptBlock ([scriptblock]{
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "scripts\ux-check.ps1") -TimeoutSec 180
    })
    Invoke-ValidationStep -Name "scripts/install-decision-matrix.ps1 (mock)" -ScriptBlock ([scriptblock]{
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "scripts\install-decision-matrix.ps1") -TimeoutSec 180
    })
    Invoke-ValidationStep -Name "Core TestSafe sandbox flow" -ScriptBlock ([scriptblock]{ Invoke-CoreSandboxFlow })
}

function Invoke-ReleaseValidation {
    Write-ValidationHeader "Release validation"

    Invoke-ValidationStep -Name "build release ZIP (isolated output)" -ScriptBlock ([scriptblock]{
        $releaseOutput = Join-Path $script:RunRoot 'release-output'
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "scripts\build-release.ps1") -Arguments @("-Version", $Version, '-OutputDir', $releaseOutput) -TimeoutSec 300
    })
    Invoke-ValidationStep -Name "release ZIP user simulation" -ScriptBlock ([scriptblock]{
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "scripts\simulate-user-release.ps1") -Arguments @("-Version", $Version) -TimeoutSec 600
    })
    $releaseSimulationPassed = [bool]$script:LastStepSucceeded
    Invoke-ValidationStep -Name "sandbox full user simulation (scenarios A-P)" -ScriptBlock ([scriptblock]{
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "scripts\sandbox-full-user-simulation.ps1") -Arguments @("-Version", $Version) -TimeoutSec 900
    })
    Invoke-ValidationStep -Name "Windows scenario matrix" -ScriptBlock ([scriptblock]{
        $matrixArguments = @('-Version', $Version, '-Quick')
        if ($releaseSimulationPassed) { $matrixArguments += '-AssumePreviousSimulationPassed' }
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "scripts\windows-scenario-matrix.ps1") -Arguments $matrixArguments -TimeoutSec 300
    })
}

function Invoke-HardcoreValidation {
    Write-ValidationHeader "Hardcore validation (failure catalog + extreme scenarios + repair matrix)"

    Invoke-ValidationStep -Name "scripts/claude-failure-catalog.ps1" -ScriptBlock ([scriptblock]{
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "scripts\claude-failure-catalog.ps1") -TimeoutSec 180
    })
    Invoke-ValidationStep -Name "scripts/hardcore-scenario-matrix.ps1" -ScriptBlock ([scriptblock]{
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "scripts\hardcore-scenario-matrix.ps1") -Arguments @("-Version", $Version) -TimeoutSec 300
    })
    Invoke-ValidationStep -Name "scripts/doctor-repair-matrix.ps1" -ScriptBlock ([scriptblock]{
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "scripts\doctor-repair-matrix.ps1") -Arguments @("-Version", $Version) -TimeoutSec 180
    })
    Invoke-ValidationStep -Name "scripts/check.ps1" -ScriptBlock ([scriptblock]{
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "scripts\check.ps1") -TimeoutSec 300
    })
}

function Get-RepositoryArtifactSnapshot {
    $snapshot = [ordered]@{}
    foreach ($fileName in @("report.txt", "support-feedback.txt")) {
        $path = Join-Path $RootDir $fileName
        $snapshot[$fileName] = if (Test-Path -LiteralPath $path -PathType Leaf) {
            $item = Get-Item -LiteralPath $path
            [ordered]@{ Exists = $true; Length = $item.Length; SHA256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
        }
        else { [ordered]@{ Exists = $false; Length = 0; SHA256 = $null } }
    }
    foreach ($dirName in @("logs", "reports", "runs", "backup")) {
        $dirPath = Join-Path $RootDir $dirName
        $files = @()
        if (Test-Path -LiteralPath $dirPath -PathType Container) {
            $files = @(Get-ChildItem -LiteralPath $dirPath -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $relative = $_.FullName.Substring($dirPath.Length).TrimStart('\', '/')
                "$relative|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
            } | Sort-Object)
        }
        $snapshot[$dirName] = [ordered]@{ Exists = (Test-Path -LiteralPath $dirPath -PathType Container); Files = $files }
    }
    return $snapshot
}

function Assert-RepositoryArtifactsUnchanged {
    param($Before, $After)
    foreach ($name in $Before.Keys) {
        $beforeJson = $Before[$name] | ConvertTo-Json -Depth 5 -Compress
        $afterJson = $After[$name] | ConvertTo-Json -Depth 5 -Compress
        if ($beforeJson -ne $afterJson) {
            throw "Repository artifact changed during validation: $name"
        }
    }
}

$validationExitCode = 1
$beforeSettings = $null
$beforeArtifacts = $null
try {
    # Git 可用性检查（必须在 try 内，确保异常能被 catch 捕获并保留 RunRoot）
    $gitAvailable = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
    if (-not $gitAvailable) {
        throw "git is not available. Validation cannot proceed."
    }

    $beforeArtifacts = Get-RepositoryArtifactSnapshot
    $beforeSettings = Get-RealSettingsSnapshot

    # 测试专用：前置快照阶段抛出异常，验证 RunRoot 保留逻辑
    if ($TestForcePreflightFailure) {
        throw "Intentional preflight failure requested by -TestForcePreflightFailure"
    }

    Write-Host "[validate] Mode=$Mode Version=$Version Branch=$(git branch --show-current) RequireClean=$requireCleanForRun"
    Write-Host "[validate] Real settings baseline: Exists=$($beforeSettings.Exists) Length=$($beforeSettings.Length) SHA256=$($beforeSettings.SHA256)"

    $script:SettingsBackup = $null
    if ($beforeSettings.Exists) {
        $script:SettingsBackup = Backup-RealSettings
    }

    if ($requireCleanForRun) {
        Invoke-ValidationStep -Name "git status clean" -ScriptBlock {
            $status = git status --short
            if ($status) { throw ("Working tree is not clean:`n" + ($status -join "`n")) }
        }
    }

    switch ($Mode) {
        "Smoke" { Invoke-SmokeValidation }
        "Full" { Invoke-FullValidation }
        "Release" { Invoke-ReleaseValidation }
        "Hardcore" { Invoke-HardcoreValidation }
        "All" { Invoke-FullValidation; Invoke-ReleaseValidation; Invoke-HardcoreValidation }
    }

    if ($TestForceFailure) {
        Invoke-ValidationStep -Name "intentional validation failure (test only)" -ScriptBlock {
            throw "intentional validation failure requested by -TestForceFailure"
        }
    }

    $afterSettings = Get-RealSettingsSnapshot
    Invoke-ValidationStep -Name "real settings.json unchanged" -ScriptBlock ([scriptblock]{
        try { Assert-RealSettingsUnchanged -Before $beforeSettings -After $afterSettings }
        catch {
            $backupInfo = if ($script:SettingsBackup) { " Backup available: $($script:SettingsBackup.BackupPath) (SHA256: $($script:SettingsBackup.SHA256))" } else { " No backup was taken." }
            throw ($_.Exception.Message + $backupInfo)
        }
    })

    $afterArtifacts = Get-RepositoryArtifactSnapshot
    Invoke-ValidationStep -Name "repository diagnostic artifacts unchanged" -ScriptBlock ([scriptblock]{
        Assert-RepositoryArtifactsUnchanged -Before $beforeArtifacts -After $afterArtifacts
    })

    if ($requireCleanForRun) {
        Invoke-ValidationStep -Name "final git status clean" -ScriptBlock {
            $status = git status --short
            if ($status) { throw ("Working tree is not clean after validation:`n" + ($status -join "`n")) }
        }
    }

    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "  Validation Summary" -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "  Mode:              $Mode"
    Write-Host "  Version:           $Version"
    Write-Host "  Branch:            $(git branch --show-current)"
    Write-Host "  RequireClean:      $requireCleanForRun"
    Write-Host "  Real settings:     Exists=$($beforeSettings.Exists) Length=$($beforeSettings.Length) SHA256=$($beforeSettings.SHA256)"
    Write-Host "  Steps executed:    $script:StepCount"
    Write-Host "  Failures:          $($script:Failures.Count)"

    if ($script:Failures.Count -gt 0) {
        Write-Host ""
        Write-Host "==============================================================" -ForegroundColor Red
        Write-Host "  Validation FAILED: $($script:Failures.Count) step(s)" -ForegroundColor Red
        Write-Host "==============================================================" -ForegroundColor Red
        foreach ($failure in $script:Failures) { Write-Host "  - $failure" -ForegroundColor Red }
        $validationExitCode = 1
    }
    else {
        Write-Host ""
        Write-Host "==============================================================" -ForegroundColor Green
        Write-Host "  Validation PASSED: $($script:StepCount) step(s)" -ForegroundColor Green
        Write-Host "==============================================================" -ForegroundColor Green
        $validationExitCode = 0
    }
}
catch {
    Write-Host "[validate] UNEXPECTED FAILURE: $($_.Exception.Message)" -ForegroundColor Red
    $validationExitCode = 1
}
finally {
    if ($script:OldTestMode) { $env:CCDI_TEST_MODE = $script:OldTestMode } else { Remove-Item Env:\CCDI_TEST_MODE -ErrorAction SilentlyContinue }
    if ($script:OldArtifactRoot) { $env:CCDI_TEST_ARTIFACT_ROOT = $script:OldArtifactRoot } else { Remove-Item Env:\CCDI_TEST_ARTIFACT_ROOT -ErrorAction SilentlyContinue }

    if ($validationExitCode -eq 0) {
        try {
            Remove-Item -LiteralPath $script:RunRoot -Recurse -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $script:RunRoot) {
                throw "RunRoot still exists after cleanup"
            }
            Write-Host "Validation artifacts cleaned."
        }
        catch {
            $validationExitCode = 1
            Write-Host "Validation artifact cleanup failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Validation artifacts preserved at: $script:RunRoot" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "Validation artifacts preserved at: $script:RunRoot" -ForegroundColor Yellow
    }
}

exit $validationExitCode
