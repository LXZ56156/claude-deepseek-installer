# ============================================================
# scripts/install-decision-matrix.ps1 - Windows Install Decision Matrix
# Mock testing of the install decision tree in lib/claude-install.ps1.
# NEVER performs real downloads, installs, or upgrades.
# Prerequisites: CCDI_TEST_MODE=1 + CCDI_MOCK_INSTALL_DECISION=1
# ============================================================

param(
    [switch]$KeepSandbox
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $PSScriptRoot
Set-Location $RootDir

. (Join-Path $RootDir "lib\bootstrap.ps1")
$null = Initialize-CcdiScript -ScriptName "install-decision-matrix"

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "  Windows Install Decision Matrix (Mock)" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""

$script:Passed = 0
$script:Failed = 0
$script:Total = 0
$script:Failures = New-Object System.Collections.ArrayList

# Test case definitions
$testCases = @(
    @{
        Id          = "DEC-001"
        Name        = "claude already installed and usable"
        Mock        = @{
            CCDI_MOCK_CLAUDE         = "ok"
            CCDI_MOCK_OFFICIAL       = "reachable"
            CCDI_MOCK_NATIVE_INSTALL = "success"
        }
        Expected    = @{
            Method              = "existing"
            Status              = "skipped_existing"
            WasAlreadyInstalled = $true
            Success             = $true
        }
        NotExpected = @("official_native", "npm_npmmirror")
    },
    @{
        Id          = "DEC-002"
        Name        = "claude command exists but broken (--version fails)"
        Mock        = @{
            CCDI_MOCK_CLAUDE         = "broken"
            CCDI_MOCK_OFFICIAL       = "reachable"
            CCDI_MOCK_NATIVE_INSTALL = "success"
        }
        Expected    = @{
            Method              = "official_native"
            Status              = "installed"
            WasAlreadyInstalled = $false
            Success             = $true
        }
        NotExpected = @("existing")
    },
    @{
        Id          = "DEC-003"
        Name        = "official channel reachable + native install success"
        Mock        = @{
            CCDI_MOCK_CLAUDE         = "missing"
            CCDI_MOCK_OFFICIAL       = "reachable"
            CCDI_MOCK_NATIVE_INSTALL = "success"
        }
        Expected    = @{
            Method              = "official_native"
            Status              = "installed"
            WasAlreadyInstalled = $false
            Success             = $true
        }
    },
    @{
        Id          = "DEC-004"
        Name        = "native install fails, fallback to npmmirror success"
        Mock        = @{
            CCDI_MOCK_CLAUDE         = "missing"
            CCDI_MOCK_OFFICIAL       = "reachable"
            CCDI_MOCK_NATIVE_INSTALL = "fail"
            CCDI_MOCK_NODE           = "ok"
            CCDI_MOCK_NPM            = "ok"
            CCDI_MOCK_NPMMIRROR      = "reachable"
            CCDI_MOCK_NPM_INSTALL    = "success"
        }
        Expected    = @{
            Method              = "npm_npmmirror"
            Status              = "installed"
            WasAlreadyInstalled = $false
            Success             = $true
        }
    },
    @{
        Id          = "DEC-005"
        Name        = "official unreachable, npmmirror success"
        Mock        = @{
            CCDI_MOCK_CLAUDE      = "missing"
            CCDI_MOCK_OFFICIAL    = "unreachable"
            CCDI_MOCK_NODE        = "ok"
            CCDI_MOCK_NPM         = "ok"
            CCDI_MOCK_NPMMIRROR   = "reachable"
            CCDI_MOCK_NPM_INSTALL = "success"
        }
        Expected    = @{
            Method              = "npm_npmmirror"
            Status              = "installed"
            WasAlreadyInstalled = $false
            Success             = $true
        }
    },
    @{
        Id          = "DEC-006"
        Name        = "official unreachable + Node.js missing"
        Mock        = @{
            CCDI_MOCK_CLAUDE    = "missing"
            CCDI_MOCK_OFFICIAL  = "unreachable"
            CCDI_MOCK_NODE      = "missing"
            CCDI_MOCK_WINGET    = "missing"
        }
        Expected    = @{
            Status              = "failed_missing_node_or_npm"
            WasAlreadyInstalled = $false
            Success             = $false
        }
    },
    @{
        Id          = "DEC-007"
        Name        = "official unreachable + npm missing"
        Mock        = @{
            CCDI_MOCK_CLAUDE    = "missing"
            CCDI_MOCK_OFFICIAL  = "unreachable"
            CCDI_MOCK_NODE      = "ok"
            CCDI_MOCK_NPM       = "missing"
        }
        Expected    = @{
            Status              = "failed_missing_node_or_npm"
            WasAlreadyInstalled = $false
            Success             = $false
        }
    },
    @{
        Id          = "DEC-008"
        Name        = "official unreachable + npmmirror unreachable"
        Mock        = @{
            CCDI_MOCK_CLAUDE     = "missing"
            CCDI_MOCK_OFFICIAL   = "unreachable"
            CCDI_MOCK_NODE       = "ok"
            CCDI_MOCK_NPM        = "ok"
            CCDI_MOCK_NPMMIRROR  = "unreachable"
        }
        Expected    = @{
            Status              = "failed_npmmirror_unreachable"
            WasAlreadyInstalled = $false
            Success             = $false
        }
    },
    @{
        Id          = "DEC-009"
        Name        = "official native fails + npm mirror install fails"
        Mock        = @{
            CCDI_MOCK_CLAUDE         = "missing"
            CCDI_MOCK_OFFICIAL       = "reachable"
            CCDI_MOCK_NATIVE_INSTALL = "fail"
            CCDI_MOCK_NODE           = "ok"
            CCDI_MOCK_NPM            = "ok"
            CCDI_MOCK_NPMMIRROR      = "reachable"
            CCDI_MOCK_NPM_INSTALL    = "fail"
        }
        Expected    = @{
            Status              = "failed_official_and_mirror"
            WasAlreadyInstalled = $false
            Success             = $false
        }
    },
    @{
        Id          = "DEC-010"
        Name        = "winget missing + Node.js missing, no silent install"
        Mock        = @{
            CCDI_MOCK_CLAUDE    = "missing"
            CCDI_MOCK_OFFICIAL  = "unreachable"
            CCDI_MOCK_NODE      = "missing"
            CCDI_MOCK_WINGET    = "missing"
        }
        Expected    = @{
            Status              = "failed_missing_node_or_npm"
            WasAlreadyInstalled = $false
            Success             = $false
        }
    }
)

function Write-TestHeader {
    param([string]$Id, [string]$Name)
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host ("  [{0}] {1}" -f $Id, $Name) -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
}

function Assert-Result {
    param(
        [hashtable]$Result,
        [hashtable]$Expected,
        [string[]]$NotExpected = @(),
        [string]$TestId
    )
    $errors = New-Object System.Collections.ArrayList
    foreach ($key in $Expected.Keys) {
        $expectedVal = $Expected[$key]
        $actualVal = $Result[$key]
        if ($expectedVal -is [bool]) {
            if ($actualVal -ne $expectedVal) {
                [void]$errors.Add(("[{0}] {1}: expected={2}, actual={3}" -f $TestId, $key, $expectedVal, $actualVal))
            }
        }
        else {
            if ($actualVal -ne $expectedVal) {
                [void]$errors.Add(("[{0}] {1}: expected='{2}', actual='{3}'" -f $TestId, $key, $expectedVal, $actualVal))
            }
        }
    }
    foreach ($notExpected in $NotExpected) {
        if ($Result.Method -eq $notExpected) {
            [void]$errors.Add(("[{0}] Method should NOT be '{1}'" -f $TestId, $notExpected))
        }
    }
    if ($errors.Count -gt 0) {
        $msg = $errors -join "; "
        Write-Error -Message $msg -ErrorAction Stop
    }
}

function Invoke-MockDecisionTest {
    param(
        [hashtable]$Mock,
        [hashtable]$Expected,
        [string[]]$NotExpected = @(),
        [string]$TestId,
        [string]$SandboxProfile,
        [string]$SandboxDesktop
    )
    Remove-Item $SandboxProfile -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $SandboxDesktop -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $SandboxProfile -Force | Out-Null
    New-Item -ItemType Directory -Path $SandboxDesktop -Force | Out-Null

    $env:CCDI_TEST_MODE = "1"
    $env:CCDI_MOCK_INSTALL_DECISION = "1"
    $env:CCDI_TEST_USERPROFILE = $SandboxProfile
    $env:CCDI_TEST_DESKTOP = $SandboxDesktop
    $env:CCDI_API_KEY = ""

    foreach ($key in $Mock.Keys) {
        Set-Item -Path ("Env:{0}" -f $key) -Value $Mock[$key]
    }

    try {
        $mockVarsText = (($Mock.Keys | ForEach-Object { "{0}={1}" -f $_, $Mock[$_] }) -join ', ')
        Write-Log "INFO" ("[{0}] Mock vars: {1}" -f $TestId, $mockVarsText)

        $result = Install-ClaudeCodeAuto -NonInteractive

        Write-Log "INFO" ("[{0}] Result: Method={1}, Status={2}, Success={3}, WasAlreadyInstalled={4}" -f $TestId, $result.Method, $result.Status, $result.Success, $result.WasAlreadyInstalled)

        Assert-Result -Result $result -Expected $Expected -NotExpected $NotExpected -TestId $TestId
        return $result
    }
    finally {
        foreach ($key in $Mock.Keys) {
            Remove-Item -Path ("Env:{0}" -f $key) -ErrorAction SilentlyContinue
        }
        Remove-Item -Path "Env:CCDI_MOCK_INSTALL_DECISION" -ErrorAction SilentlyContinue
    }
}

# Main
$sandboxRoot = Join-Path $RootDir ".sandbox\install-decision-matrix"
$sandboxProfile = Join-Path $sandboxRoot "userprofile"
$sandboxDesktop = Join-Path $sandboxRoot "desktop"

$oldEnv = @{
    CCDI_TEST_MODE        = $env:CCDI_TEST_MODE
    CCDI_TEST_USERPROFILE = $env:CCDI_TEST_USERPROFILE
    CCDI_TEST_DESKTOP     = $env:CCDI_TEST_DESKTOP
    CCDI_API_KEY          = $env:CCDI_API_KEY
}

try {
    foreach ($case in $testCases) {
        $script:Total++
        Write-TestHeader -Id $case.Id -Name $case.Name
        try {
            $notExp = if ($case.ContainsKey("NotExpected")) { $case.NotExpected } else { @() }
            $result = Invoke-MockDecisionTest `
                -Mock $case.Mock `
                -Expected $case.Expected `
                -NotExpected $notExp `
                -TestId $case.Id `
                -SandboxProfile $sandboxProfile `
                -SandboxDesktop $sandboxDesktop

            Write-Host ("[{0}] PASS: Method={1} Status={2}" -f $case.Id, $result.Method, $result.Status) -ForegroundColor Green
            $script:Passed++
        }
        catch {
            Write-Host ("[{0}] FAIL: {1}" -f $case.Id, $_.Exception.Message) -ForegroundColor Red
            [void]$script:Failures.Add(("[{0}] {1}: {2}" -f $case.Id, $case.Name, $_.Exception.Message))
            $script:Failed++
        }
    }
}
finally {
    foreach ($name in $oldEnv.Keys) {
        if ($oldEnv[$name]) {
            Set-Item -Path ("Env:{0}" -f $name) -Value $oldEnv[$name]
        }
        else {
            Remove-Item -Path ("Env:{0}" -f $name) -ErrorAction SilentlyContinue
        }
    }
    if (-not $KeepSandbox) {
        Remove-Item $sandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "  Install Decision Matrix Summary" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ("  Total:   {0}" -f $script:Total)
Write-Host ("  Passed:  {0}" -f $script:Passed) -ForegroundColor Green
$failColor = if ($script:Failed -gt 0) { "Red" } else { "Green" }
Write-Host ("  Failed:  {0}" -f $script:Failed) -ForegroundColor $failColor

if ($script:Failures.Count -gt 0) {
    Write-Host ""
    Write-Host "  Failures:" -ForegroundColor Red
    foreach ($f in $script:Failures) {
        Write-Host ("  - {0}" -f $f) -ForegroundColor Red
    }
    exit 1
}

Write-Host ""
Write-Host "[install-decision-matrix] OK" -ForegroundColor Green
exit 0
