# ============================================================
# debug-claude-doctor.ps1 — Temporary Debug Script
# Purpose: Validate Invoke-ClaudeDoctorInteractiveSafe function
# Note: Does NOT test Invoke-CommandSafe claude doctor (dangerous,
#       leaves orphaned processes). Delete after verification.
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$DebugScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ProjectRoot = Split-Path -Parent $DebugScriptDir

Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "  claude doctor Verification Script (Debug Only)"
Write-Host "  Project Root: $ProjectRoot"
Write-Host "  Start Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""

# Load libraries
. (Join-Path $ProjectRoot "lib\bootstrap.ps1")
$null = Initialize-CcdiScript -ScriptName "debug-claude-doctor"

# ============================================================
# Helper Functions
# ============================================================

function Limit-String {
    param([string]$Text, [int]$MaxLen = 2000)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "(empty)" }
    if ($Text.Length -le $MaxLen) { return $Text }
    return $Text.Substring(0, $MaxLen) + "`n... [TRUNCATED, total $($Text.Length) chars]"
}

function Get-ProcessSnapshot {
    param([string]$Label)
    $procs = @(Get-Process -Name "claude" -ErrorAction SilentlyContinue | Select-Object Id,ProcessName,StartTime,MainWindowTitle)
    Write-Host "  [$Label] Claude processes:" -ForegroundColor DarkGray
    if ($procs.Count -eq 0) {
        Write-Host "    (none)" -ForegroundColor DarkGray
    } else {
        foreach ($p in $procs) {
            Write-Host "    PID=$($p.Id) StartTime=$($p.StartTime) Title=$($p.MainWindowTitle)" -ForegroundColor DarkGray
        }
    }
    return $procs
}

# ============================================================
# Part 1: Environment Info
# ============================================================

Write-Host "========== Part 1: Environment ==========" -ForegroundColor Yellow
Write-Host "PowerShell: $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)"
Write-Host "CWD: $(Get-Location)"
Write-Host "ComSpec: $env:ComSpec"
Write-Host "TEMP: $env:TEMP"
Write-Host ""

Write-Host "[1a] Get-Command claude -All" -ForegroundColor Cyan
$allClaude = Get-Command claude -All -ErrorAction SilentlyContinue
if ($allClaude) {
    foreach ($c in $allClaude) {
        Write-Host "  CommandType: $($c.CommandType)"
        Write-Host "  Source:      $($c.Source)"
        Write-Host "  Definition:  $($c.Definition)"
        Write-Host "  ---"
    }
} else {
    Write-Host "  (none)" -ForegroundColor Red
}
Write-Host ""

Write-Host "[1b] where.exe claude" -ForegroundColor Cyan
try {
    $whereResult = & where.exe claude 2>&1
    Write-Host "  $whereResult"
} catch {
    Write-Host "  Failed: $_" -ForegroundColor Red
}
Write-Host ""

# ============================================================
# Part 2: Test Invoke-CommandSafe claude --version (safe control)
# ============================================================

Write-Host "========== Part 2: Invoke-CommandSafe claude --version ==========" -ForegroundColor Yellow
Write-Host "This is a safe control test to verify Invoke-CommandSafe works."
Write-Host ""

Get-ProcessSnapshot -Label "before-ctrl"
$swCtrl = [System.Diagnostics.Stopwatch]::StartNew()
$resultCtrl = Invoke-CommandSafe -Command "claude" -Arguments @("--version") -TimeoutSec 30
$swCtrl.Stop()
Get-ProcessSnapshot -Label "after-ctrl"

Write-Host "[Control] Duration: $($swCtrl.Elapsed.TotalSeconds.ToString('F2'))s" -ForegroundColor Green
Write-Host "[Control] Success: $($resultCtrl.Success), ExitCode: $($resultCtrl.ExitCode)"
Write-Host "[Control] Output: $(Limit-String $resultCtrl.Output -MaxLen 500)"
if ($resultCtrl.Error) {
    Write-Host "[Control] Error: $(Limit-String $resultCtrl.Error -MaxLen 500)"
}
Write-Host ""

# ============================================================
# Part 3: Test Invoke-ClaudeDoctorInteractiveSafe
# ============================================================

Write-Host "========== Part 3: Invoke-ClaudeDoctorInteractiveSafe ==========" -ForegroundColor Yellow
Write-Host "This runs claude doctor inline with watchdog timeout protection."
Write-Host "It inherits the current terminal (no Start-Process/cmd.exe/redirect)."
Write-Host ""

# Clear stale processes first
Write-Host "[Pre-clean] Clearing stale claude doctor processes..." -ForegroundColor Cyan
$preClean = Clear-StaleClaudeDoctorProcesses -Force
Write-Host "[Pre-clean] Cleaned $($preClean.KilledCount) stale doctor processes"
Write-Host ""

Get-ProcessSnapshot -Label "before-doctor"
Write-Host ""
Write-Host "Running Invoke-ClaudeDoctorInteractiveSafe (max 60s)..." -ForegroundColor Green
$swDoctor = [System.Diagnostics.Stopwatch]::StartNew()
$resultDoctor = Invoke-ClaudeDoctorInteractiveSafe -TimeoutSec 60
$swDoctor.Stop()
Get-ProcessSnapshot -Label "after-doctor"

$doctorColor = if ($resultDoctor.Success) { "Green" } elseif ($resultDoctor.TimedOut) { "Red" } else { "Yellow" }
Write-Host ""
Write-Host "[Doctor] Duration: $($swDoctor.Elapsed.TotalSeconds.ToString('F2'))s" -ForegroundColor $doctorColor
Write-Host "[Doctor] Success: $($resultDoctor.Success)" -ForegroundColor $doctorColor
Write-Host "[Doctor] TimedOut: $($resultDoctor.TimedOut)" -ForegroundColor $doctorColor
Write-Host "[Doctor] ExitCode: $($resultDoctor.ExitCode)" -ForegroundColor $doctorColor
Write-Host "[Doctor] Command: $($resultDoctor.Command)" -ForegroundColor $doctorColor
Write-Host "[Doctor] DurationMs: $($resultDoctor.DurationMs)" -ForegroundColor $doctorColor
Write-Host "[Doctor] Error: $($resultDoctor.Error)" -ForegroundColor $doctorColor

# Post-clean: ensure no residual doctor processes
Write-Host ""
Write-Host "[Post-clean] Ensuring no residual doctor processes..." -ForegroundColor Cyan
$postClean = Clear-StaleClaudeDoctorProcesses -Force
Write-Host "[Post-clean] Cleaned $($postClean.KilledCount) residual doctor processes"

# ============================================================
# Part 4: Summary
# ============================================================

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "  Verification Summary" -ForegroundColor Yellow
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""

$ctrlStatus = if ($resultCtrl.Success) { "[OK]" } else { "[FAIL]" }
$doctorStatus = if ($resultDoctor.Success) { "[OK]" } elseif ($resultDoctor.TimedOut) { "[TIMEOUT]" } else { "[WARN]" }

Write-Host "  Invoke-CommandSafe claude --version: $ctrlStatus ($($swCtrl.Elapsed.TotalSeconds.ToString('F2'))s)"
Write-Host "  Invoke-ClaudeDoctorInteractiveSafe: $doctorStatus ($($swDoctor.Elapsed.TotalSeconds.ToString('F2'))s)"
Write-Host "  Claude path: $($resultDoctor.Command)"
Write-Host "  Stale doctor cleaned before: $($preClean.KilledCount)"
Write-Host "  Residual doctor cleaned after: $($postClean.KilledCount)"

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "  Debug script complete." -ForegroundColor Cyan
Write-Host "  Note: Invoke-CommandSafe claude doctor was NOT tested"
Write-Host "        (known to leave orphaned processes)." -ForegroundColor Yellow
Write-Host "==============================================================" -ForegroundColor Cyan
