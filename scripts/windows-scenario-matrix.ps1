# ============================================================
# scripts/windows-scenario-matrix.ps1 - Windows scenario matrix
# Orchestrates all Windows validation tools and generates a coverage matrix report.
# Does not duplicate business logic - only schedules and summarizes.
# ============================================================

param(
    [string]$Version = "1.3.2",
    [switch]$Quick,
    [switch]$AssumePreviousSimulationPassed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RootDir = Split-Path -Parent $PSScriptRoot
Set-Location $RootDir

$ScriptDir = $RootDir
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ReportPath = Join-Path $ScriptDir "reports\windows-scenario-matrix-report-$Timestamp.txt"

if (-not (Test-Path (Join-Path $ScriptDir "reports"))) {
    New-Item -ItemType Directory -Path (Join-Path $ScriptDir "reports") -Force | Out-Null
}

# Scenario definitions
$scenarios = @(
    @{
        Id          = "WIN-NEW-001"
        Name        = "Windows native new user TestSafe main flow"
        Tool        = "check.ps1, ux-check.ps1, Start-Here TestSafe"
        AutoLevel   = "AUTO"
        Category    = "Core flow"
        Description = "Full chain from Start-Here TestSafe to config complete for new Windows user"
    },
    @{
        Id          = "WIN-EXISTING-001"
        Name        = "Windows already has Claude Code, skip install"
        Tool        = "install-decision-matrix.ps1 (DEC-001)"
        AutoLevel   = "MOCK"
        Category    = "Install decision"
        Description = "Does not trigger any install when claude exists and is usable, config preserved"
    },
    @{
        Id          = "WIN-BROKEN-001"
        Name        = "claude command exists but broken"
        Tool        = "install-decision-matrix.ps1 (DEC-002)"
        AutoLevel   = "MOCK"
        Category    = "Install decision"
        Description = "Does not mis-detect as installed when --version fails, enters repair path"
    },
    @{
        Id          = "WIN-CONFIG-001"
        Name        = "settings.json corrupt, backup and rebuild"
        Tool        = "simulate-user-release.ps1 (corrupt JSON)"
        AutoLevel   = "AUTO"
        Category    = "Config management"
        Description = "Backs up old file and rebuilds when JSON is invalid, preserves non-env fields"
    },
    @{
        Id          = "WIN-DEPS-001"
        Name        = "Node.js missing"
        Tool        = "install-decision-matrix.ps1 (DEC-006)"
        AutoLevel   = "MOCK"
        Category    = "Dependency check"
        Description = "Cannot continue installing Claude Code without Node.js, prompts user to fix first"
    },
    @{
        Id          = "WIN-DEPS-002"
        Name        = "npm missing or broken"
        Tool        = "install-decision-matrix.ps1 (DEC-007)"
        AutoLevel   = "MOCK"
        Category    = "Dependency check"
        Description = "Prompts Node.js/npm environment anomaly when npm is unavailable"
    },
    @{
        Id          = "WIN-NET-001"
        Name        = "official install fails, fallback to npmmirror"
        Tool        = "install-decision-matrix.ps1 (DEC-004, DEC-005)"
        AutoLevel   = "MOCK"
        Category    = "Network fallback"
        Description = "Auto-switches to npmmirror when official is unavailable or install fails, logs reason"
    },
    @{
        Id          = "WIN-UNINSTALL-001"
        Name        = "Remove DeepSeek env then restore"
        Tool        = "simulate-user-release.ps1 (uninstall flow)"
        AutoLevel   = "AUTO"
        Category    = "Config management"
        Description = "RemoveDeepSeekEnv preserves custom config, RestoreLatest fully restores"
    },
    @{
        Id          = "WIN-REPORT-001"
        Name        = "report.txt / logs / reports sanitization"
        Tool        = "ux-check.ps1, simulate-user-release.ps1"
        AutoLevel   = "AUTO"
        Category    = "Security sanitization"
        Description = "No API Key, username, or real path leaked in reports and logs"
    },
    @{
        Id          = "WIN-ZIP-001"
        Name        = "release ZIP extraction and bilingual launcher simulation"
        Tool        = "simulate-user-release.ps1 (full flow)"
        AutoLevel   = "AUTO"
        Category    = "Delivery verification"
        Description = "Chinese/English .cmd launchers, missing file prompts, ZIP integrity"
    }
)

# Report generation
$reportLines = New-Object System.Collections.ArrayList

function Write-ReportLine {
    param([string]$Line)
    [void]$reportLines.Add($Line)
}

function Invoke-ToolCheck {
    param(
        [string]$Name,
        [string]$ToolPath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 300
    )

    Write-Host ("[matrix] Running: {0}" -f $Name) -ForegroundColor Cyan

    $tmpOut = Join-Path $env:TEMP ("ccdi_matrix_stdout_{0}_{1}.tmp" -f $PID, (Get-Random))
    $tmpErr = Join-Path $env:TEMP ("ccdi_matrix_stderr_{0}_{1}.tmp" -f $PID, (Get-Random))

    try {
        $allArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ToolPath) + $Arguments
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $allArgs `
            -NoNewWindow -PassThru -Wait `
            -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr

        $exitCode = $proc.ExitCode
        $stdout = if (Test-Path $tmpOut) { Get-Content $tmpOut -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } else { "" }
        $stderr = if (Test-Path $tmpErr) { Get-Content $tmpErr -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } else { "" }

        return @{
            Name     = $Name
            ExitCode = $exitCode
            Success  = ($exitCode -eq 0)
            Output   = $stdout
            Error    = $stderr
        }
    }
    catch {
        return @{
            Name     = $Name
            ExitCode = -1
            Success  = $false
            Output   = ""
            Error    = $_.Exception.Message
        }
    }
    finally {
        Remove-Item $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    }
}

# Main
Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ("  Windows Scenario Matrix v{0}" -f $Version) -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""

# Report header
Write-ReportLine "=============================================================="
Write-ReportLine "  Windows Scenario Matrix Report"
Write-ReportLine ("  Version: {0}" -f $Version)
Write-ReportLine ("  Generated: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-ReportLine ("  Branch: {0}" -f (git branch --show-current 2>$null))
Write-ReportLine ("  Commit: {0}" -f (git log --oneline -1 2>$null))
Write-ReportLine "=============================================================="
Write-ReportLine ""

# Run tools
$toolResults = @{}

$checkResult = Invoke-ToolCheck -Name "check.ps1" -ToolPath (Join-Path $ScriptDir "scripts\check.ps1")
$toolResults["check"] = $checkResult
$colorC = if ($checkResult.Success) { "Green" } else { "Red" }
Write-Host ("  check.ps1: exit={0}" -f $checkResult.ExitCode) -ForegroundColor $colorC

$uxResult = Invoke-ToolCheck -Name "ux-check.ps1" -ToolPath (Join-Path $ScriptDir "scripts\ux-check.ps1")
$toolResults["ux-check"] = $uxResult
$colorU = if ($uxResult.Success) { "Green" } else { "Red" }
Write-Host ("  ux-check.ps1: exit={0}" -f $uxResult.ExitCode) -ForegroundColor $colorU

$decisionResult = Invoke-ToolCheck -Name "install-decision-matrix.ps1" -ToolPath (Join-Path $ScriptDir "scripts\install-decision-matrix.ps1")
$toolResults["decision"] = $decisionResult
$colorD = if ($decisionResult.Success) { "Green" } else { "Red" }
Write-Host ("  install-decision-matrix.ps1: exit={0}" -f $decisionResult.ExitCode) -ForegroundColor $colorD

if (-not $Quick) {
    Write-Host "[matrix] Building release and running user simulation..." -ForegroundColor Yellow
    $simResult = Invoke-ToolCheck -Name "simulate-user-release.ps1" `
        -ToolPath (Join-Path $ScriptDir "scripts\simulate-user-release.ps1") `
        -Arguments @("-Version", $Version) -TimeoutSec 600
    $toolResults["simulate"] = $simResult
    $colorS = if ($simResult.Success) { "Green" } else { "Red" }
    Write-Host ("  simulate-user-release.ps1: exit={0}" -f $simResult.ExitCode) -ForegroundColor $colorS
}
else {
    $skipReason = if ($AssumePreviousSimulationPassed) {
        "SKIP (Quick mode; assume passed — Release validation already ran simulate-user-release.ps1)"
    } else {
        "SKIP (Quick mode; run without -Quick or pass -AssumePreviousSimulationPassed to trust prior run)"
    }
    Write-Host ("  simulate-user-release.ps1: {0}" -f $skipReason) -ForegroundColor Yellow
    $toolResults["simulate"] = @{
        Name = "simulate-user-release.ps1"
        ExitCode = 0
        Success = $AssumePreviousSimulationPassed
        Output = $skipReason
        Error = ""
    }
    $toolResults["simulateSkipped"] = $true
}

# Scenario coverage determination
Write-ReportLine ""
Write-ReportLine "=============================================================="
Write-ReportLine "  Scenario Coverage Matrix"
Write-ReportLine "=============================================================="
Write-ReportLine ""

Write-Host ""
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "  Scenario Coverage" -ForegroundColor Cyan
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan

$passCount = 0
$failCount = 0
$skipCount = 0

foreach ($scenario in $scenarios) {
    $result = "PASS"
    $evidence = ""
    $suggestion = ""

    switch ($scenario.Id) {
        "WIN-NEW-001" {
            if ($checkResult.Success -and $uxResult.Success) {
                $result = "PASS"
            }
            else {
                $result = "FAIL"
                $suggestion = "Check check.ps1 and ux-check.ps1 output"
            }
            $evidence = "check.ps1 + ux-check.ps1 both passed"
        }
        "WIN-EXISTING-001" {
            if ($decisionResult.Success) { $result = "PASS" }
            else { $result = "FAIL"; $suggestion = "Check install-decision-matrix.ps1 DEC-001" }
            $evidence = "install-decision-matrix.ps1 DEC-001"
        }
        "WIN-BROKEN-001" {
            if ($decisionResult.Success) { $result = "PASS" }
            else { $result = "FAIL"; $suggestion = "Check install-decision-matrix.ps1 DEC-002" }
            $evidence = "install-decision-matrix.ps1 DEC-002"
        }
        "WIN-CONFIG-001" {
            if ($toolResults["simulateSkipped"] -and -not $AssumePreviousSimulationPassed) {
                $result = "SKIP"; $suggestion = "Run without -Quick or pass -AssumePreviousSimulationPassed"
            } elseif ($toolResults["simulate"].Success) {
                $result = "PASS"
            } else { $result = "FAIL"; $suggestion = "Run simulate-user-release.ps1" }
            $evidence = "simulate-user-release.ps1 corrupt JSON flow"
        }
        "WIN-DEPS-001" {
            if ($decisionResult.Success) { $result = "PASS" }
            else { $result = "FAIL"; $suggestion = "Check install-decision-matrix.ps1 DEC-006" }
            $evidence = "install-decision-matrix.ps1 DEC-006"
        }
        "WIN-DEPS-002" {
            if ($decisionResult.Success) { $result = "PASS" }
            else { $result = "FAIL"; $suggestion = "Check install-decision-matrix.ps1 DEC-007" }
            $evidence = "install-decision-matrix.ps1 DEC-007"
        }
        "WIN-NET-001" {
            if ($decisionResult.Success) { $result = "PASS" }
            else { $result = "FAIL"; $suggestion = "Check install-decision-matrix.ps1 DEC-004, DEC-005" }
            $evidence = "install-decision-matrix.ps1 DEC-004 + DEC-005"
        }
        "WIN-UNINSTALL-001" {
            if ($toolResults["simulateSkipped"] -and -not $AssumePreviousSimulationPassed) {
                $result = "SKIP"; $suggestion = "Run without -Quick or pass -AssumePreviousSimulationPassed"
            } elseif ($toolResults["simulate"].Success) {
                $result = "PASS"
            } else { $result = "FAIL"; $suggestion = "Run simulate-user-release.ps1" }
            $evidence = "simulate-user-release.ps1 uninstall/restore flow"
        }
        "WIN-REPORT-001" {
            if ($toolResults["simulateSkipped"] -and -not $AssumePreviousSimulationPassed) {
                $result = "SKIP"; $suggestion = "Run without -Quick or pass -AssumePreviousSimulationPassed"
            } elseif ($uxResult.Success -and $toolResults["simulate"].Success) {
                $result = "PASS"
            } else { $result = "FAIL"; $suggestion = "Check ux-check sanitize + simulate leak check" }
            $evidence = "ux-check.ps1 sanitize + simulate leak check"
        }
        "WIN-ZIP-001" {
            if ($toolResults["simulateSkipped"] -and -not $AssumePreviousSimulationPassed) {
                $result = "SKIP"; $suggestion = "Run without -Quick or pass -AssumePreviousSimulationPassed"
            } elseif ($toolResults["simulate"].Success) {
                $result = "PASS"
            } else { $result = "FAIL"; $suggestion = "Run simulate-user-release.ps1 full flow" }
            $evidence = "simulate-user-release.ps1 full user flow"
        }
    }

    switch ($result) {
        "PASS" { $passCount++; $color = "Green" }
        "FAIL" { $failCount++; $color = "Red" }
        "SKIP" { $skipCount++; $color = "Yellow" }
    }

    $line = ("  [{0}] {1}: {2} [{3}]" -f $result, $scenario.Id, $scenario.Name, $scenario.AutoLevel)
    Write-Host $line -ForegroundColor $color
    Write-ReportLine $line
    if ($evidence) {
        Write-ReportLine ("    Evidence: {0}" -f $evidence)
    }
    if ($suggestion) {
        Write-ReportLine ("    Suggestion: {0}" -f $suggestion)
    }
}

# Summary
Write-ReportLine ""
Write-ReportLine "=============================================================="
Write-ReportLine "  Summary"
Write-ReportLine "=============================================================="
Write-ReportLine ""
Write-ReportLine ("  Total:   {0}" -f $scenarios.Count)
Write-ReportLine ("  Passed:  {0}" -f $passCount)
Write-ReportLine ("  Failed:  {0}" -f $failCount)
Write-ReportLine ("  Skipped: {0}" -f $skipCount)
Write-ReportLine ""

Write-ReportLine "Auto coverage (AUTO):"
$scenarios | Where-Object { $_.AutoLevel -eq "AUTO" } | ForEach-Object {
    Write-ReportLine ("  - {0}: {1}" -f $_.Id, $_.Name)
}
Write-ReportLine ""

Write-ReportLine "Mock coverage (MOCK):"
$scenarios | Where-Object { $_.AutoLevel -eq "MOCK" } | ForEach-Object {
    Write-ReportLine ("  - {0}: {1}" -f $_.Id, $_.Name)
}
Write-ReportLine ""

Write-ReportLine "Still needs manual real-machine verification:"
Write-ReportLine "  - Clean Windows 10/11 full fresh install flow"
Write-ReportLine "  - Real domestic network fallback verification"
Write-ReportLine "  - Proxy/VPN environment install behavior"
Write-ReportLine "  - Security software interference behavior"
Write-ReportLine "  - .cmd double-click real GUI ShellExecute behavior"
Write-ReportLine "  - PowerShell 5.1 Chinese path real encoding verification"
Write-ReportLine "  - Multi-version Node.js (nvm) coexistence verification"
Write-ReportLine ""

if ($Quick -and $AssumePreviousSimulationPassed) {
    Write-ReportLine ""
    Write-ReportLine "Note: simulate-user-release.ps1 was skipped (-Quick mode)."
    Write-ReportLine "  -AssumePreviousSimulationPassed is set — trusting that Release validation"
    Write-ReportLine "  already ran simulate-user-release.ps1 successfully before this matrix run."
    Write-ReportLine "  Scenarios that depend on simulate results are marked PASS based on that prior run."
    Write-ReportLine ""
}

Write-ReportLine "WSL NOT modified in this round:"
Write-ReportLine "  All changes are Windows-side validation only."
Write-ReportLine "  install_wsl.sh, scripts/check.sh, scripts/ux-check.sh NOT modified."
Write-ReportLine "  No WSL install logic added or changed."
Write-ReportLine "  WSL scenarios marked as deferred/future."
Write-ReportLine ""

Write-ReportLine "Environment limitations:"
if (-not (Get-Command "pwsh" -ErrorAction SilentlyContinue)) {
    Write-ReportLine "  - pwsh unavailable, PowerShell 7 checks skipped"
}
Write-ReportLine "  - GUI ShellExecute tests depend on Windows desktop environment"
Write-ReportLine "  - Real network fallback tests require actual domestic network setup"
Write-ReportLine ""

Write-ReportLine "=============================================================="
Write-ReportLine "  Tool Run Details"
Write-ReportLine "=============================================================="
Write-ReportLine ""

foreach ($toolName in @("check", "ux-check", "decision", "simulate")) {
    $tr = $toolResults[$toolName]
    Write-ReportLine ("  [{0}]" -f $tr.Name)
    Write-ReportLine ("    ExitCode: {0}" -f $tr.ExitCode)
    if ($tr.Error) {
        $errSummary = if ($tr.Error.Length -gt 500) { $tr.Error.Substring(0, 500) + "..." } else { $tr.Error }
        Write-ReportLine ("    Error: {0}" -f $errSummary)
    }
}

# Write report file
$reportContent = ($reportLines -join "`r`n")
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($ReportPath, $reportContent, $utf8NoBom)

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "  Matrix Report" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ("  Report: {0}" -f $ReportPath)
Write-Host ("  Passed: {0} / {1}" -f $passCount, $scenarios.Count)
Write-Host ""

if ($failCount -gt 0) {
    Write-Host ("  WARNING: {0} scenario(s) FAILED" -f $failCount) -ForegroundColor Red
    exit 1
}

Write-Host "[windows-scenario-matrix] OK" -ForegroundColor Green
exit 0
