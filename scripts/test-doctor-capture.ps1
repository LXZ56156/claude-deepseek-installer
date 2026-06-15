# ============================================================
# test-doctor-capture.ps1 - fake claude doctor 捕获机制动态验收
#
# 不依赖真实 Claude Code。验证：
#   A. 超时后仍能捕获 fake claude 部分 stdout
#   B. 大输出 (>4KB) 不会导致 pipe 死锁
#
# 用法: powershell -ExecutionPolicy Bypass -File .\scripts\test-doctor-capture.ps1
# ============================================================

$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $PSScriptRoot
. (Join-Path $RootDir "lib\bootstrap.ps1")

Set-StrictMode -Version Latest
if (-not (Get-Command Initialize-CcdiScript -ErrorAction SilentlyContinue)) { throw "Initialize-CcdiScript not available after loading bootstrap" }
$null = Initialize-CcdiScript -ScriptName "test-doctor-capture"

# 保存并清除 CCDI_TEST_MODE，防止 fake 测试被跳过
$oldTestMode = $env:CCDI_TEST_MODE
$oldMockDecision = $env:CCDI_MOCK_INSTALL_DECISION

function Restore-TestEnv {
    $testMode = Get-Variable -Name oldTestMode -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $testMode) {
        $env:CCDI_TEST_MODE = $testMode
    }
    else {
        Remove-Item Env:\CCDI_TEST_MODE -ErrorAction SilentlyContinue
    }
    $mockDecision = Get-Variable -Name oldMockDecision -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $mockDecision) {
        $env:CCDI_MOCK_INSTALL_DECISION = $mockDecision
    }
    else {
        Remove-Item Env:\CCDI_MOCK_INSTALL_DECISION -ErrorAction SilentlyContinue
    }
}

try {
    Remove-Item Env:\CCDI_TEST_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:\CCDI_MOCK_INSTALL_DECISION -ErrorAction SilentlyContinue

$failed = 0

# ============================================================
# 测试 A：timeout partial output
# ============================================================
Write-Host ""
Write-Host "--- Test A: fake timeout partial output ---"

$fakeDirA = $null
try {
    $fakeDirA = Join-Path ([System.IO.Path]::GetTempPath()) ("ccdi-fake-claude-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $fakeDirA | Out-Null

    Set-Content -Path (Join-Path $fakeDirA "claude.cmd") -Encoding ASCII -Value @'
@echo off
echo Claude Doctor
echo Version: fake-test-timeout
echo Platform: win32
echo Path: C:\fake\claude.exe
echo Config install method: fake
echo Auth: ok
powershell -NoProfile -Command "Start-Sleep -Seconds 20"
'@

    $oldPath = $env:PATH
    $env:PATH = "$fakeDirA;$oldPath"
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-ClaudeDoctorInteractiveSafe -TimeoutSec 3
        $sw.Stop()

        if (-not $r.TimedOut) { throw "FAIL A1: expected TimedOut=true" }
        if ($sw.ElapsedMilliseconds -ge 15000) { throw "FAIL A2: actual duration $($sw.ElapsedMilliseconds)ms >= 15s" }
        if ([string]::IsNullOrWhiteSpace($r.CleanedOutput)) { throw "FAIL A3: CleanedOutput is empty" }
        if ($r.CleanedOutput -notmatch "fake-test-timeout") { throw "FAIL A4: missing fake-test-timeout in output" }

        Write-Host "  Duration: $($sw.ElapsedMilliseconds)ms, TimedOut=True, Output=$($r.CleanedOutput.Length) bytes"
        Write-Host "[PASS] fake timeout partial output captured"
    }
    finally {
        $env:PATH = $oldPath
    }
}
catch {
    Write-Host "[ERROR] Test A failed: $_" -ForegroundColor Red
    $failed++
}
finally {
    if ($fakeDirA) { Remove-Item $fakeDirA -Recurse -Force -ErrorAction SilentlyContinue }
}

# ============================================================
# 测试 B：large output no deadlock
# ============================================================
Write-Host ""
Write-Host "--- Test B: fake large output (no pipe deadlock) ---"

$fakeDirB = $null
try {
    $fakeDirB = Join-Path ([System.IO.Path]::GetTempPath()) ("ccdi-fake-claude-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $fakeDirB | Out-Null

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('@echo off')
    [void]$sb.AppendLine('echo Version: fake-large-output')
    [void]$sb.AppendLine('echo Platform: win32')
    [void]$sb.AppendLine('echo Path: C:\fake\claude.exe')
    for ($i = 1; $i -le 2500; $i++) {
        [void]$sb.AppendLine("echo doctor-line-$i xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
    }
    [void]$sb.AppendLine('echo Version: fake-large-output')
    [void]$sb.AppendLine('exit /b 0')
    [System.IO.File]::WriteAllText((Join-Path $fakeDirB "claude.cmd"), $sb.ToString(), [System.Text.Encoding]::ASCII)

    $oldPath = $env:PATH
    $env:PATH = "$fakeDirB;$oldPath"
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-ClaudeDoctorInteractiveSafe -TimeoutSec 15
        $sw.Stop()

        if ($r.TimedOut) { throw "FAIL B1: expected no timeout, got TimedOut=true" }
        if ($r.DurationMs -ge 15000) { throw "FAIL B2: duration $($r.DurationMs)ms >= 15s" }
        if ([string]::IsNullOrWhiteSpace($r.CleanedOutput)) { throw "FAIL B3: CleanedOutput is empty" }
        if ($r.CleanedOutput -notmatch "fake-large-output") { throw "FAIL B4: missing fake-large-output in output" }
        if ($r.CleanedOutput.Length -lt 4096) { throw "FAIL B5: output too small ($($r.CleanedOutput.Length) bytes, expected >4096)" }

        Write-Host "  Duration: $($sw.ElapsedMilliseconds)ms, TimedOut=False, Output=$($r.CleanedOutput.Length) bytes"
        Write-Host "[PASS] fake large output captured without deadlock"
    }
    finally {
        $env:PATH = $oldPath
    }
}
catch {
    Write-Host "[ERROR] Test B failed: $_" -ForegroundColor Red
    $failed++
}
finally {
    if ($fakeDirB) { Remove-Item $fakeDirB -Recurse -Force -ErrorAction SilentlyContinue }
}

# ============================================================
# 结果
# ============================================================
Write-Host ""
if ($failed -eq 0) {
    Write-Host "test-doctor-capture.ps1: ALL TESTS PASSED" -ForegroundColor Green
}
else {
    Write-Host "test-doctor-capture.ps1: $failed TEST(S) FAILED" -ForegroundColor Red
}
}
finally {
    Restore-TestEnv
}

exit $failed
