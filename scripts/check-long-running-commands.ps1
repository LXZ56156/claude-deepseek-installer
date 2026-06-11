# ============================================================
# scripts/check-long-running-commands.ps1
# UX scan: detect long-running commands hidden behind
# Invoke-CommandSafe with zero user-visible progress
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RootDir = Split-Path -Parent $PSScriptRoot

Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "  Long-running command UX scan"
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""

$psFiles = Get-ChildItem -Path $RootDir -Filter "*.ps1" -Recurse |
    Where-Object { $_.FullName -notmatch '(\.sandbox|\.git|node_modules|release|backup|logs|reports)' }

$issues = @{
    HIGH   = [System.Collections.ArrayList]::new()
    MEDIUM = [System.Collections.ArrayList]::new()
    LOW    = [System.Collections.ArrayList]::new()
}

$highRiskPatterns = @(
    @{ Name = "winget install"; Pattern = 'winget.*install' },
    @{ Name = "npm install -g claude-code"; Pattern = '\bnpm\b[\s\S]{0,20}\binstall\b[\s\S]{0,20}@anthropic-ai/claude-code' },
    @{ Name = "powershell -File (install script)"; Pattern = 'powershell.*-File.*install' },
    @{ Name = "claude doctor"; Pattern = 'claude[\s\S]{0,50}doctor' },
    @{ Name = "Invoke-RestMethod download hidden by Invoke-CommandSafe"; Pattern = 'Invoke-RestMethod.*claude\.ai/install\.ps1' }
)

foreach ($file in $psFiles) {
    $content = Get-Content $file.FullName -Raw -Encoding UTF8
    if (-not $content) { continue }

    $invokeCalls = [regex]::Matches($content, 'Invoke-CommandSafe\s+-Command\s+"(\w[\w.]*)"\s*(?:-Arguments\s+@\([\s\S]*?\)\s*)?-TimeoutSec\s+(\d+)')

    foreach ($match in $invokeCalls) {
        $cmd = $match.Groups[1].Value
        $timeout = [int]$match.Groups[2].Value
        $relPath = $file.FullName.Replace($RootDir, '').TrimStart('\', '/')

        # HIGH: long-running install commands still using Invoke-CommandSafe
        foreach ($risk in $highRiskPatterns) {
            $surroundingText = $content.Substring([Math]::Max(0, $match.Index - 50), [Math]::Min(200, $content.Length - [Math]::Max(0, $match.Index - 50)))
            if ($surroundingText -match $risk.Pattern) {
                $issue = "HIGH: $($risk.Name) via Invoke-CommandSafe (${timeout}s) in $relPath"
                [void]$issues.HIGH.Add($issue)
            }
        }

        # MEDIUM: timeout >= 120 and has ProgressMessage (hidden progress)
        if ($timeout -ge 120) {
            if ($content.Substring($match.Index, [Math]::Min(300, $content.Length - $match.Index)) -match 'ProgressMessage') {
                $issue = "MEDIUM: ${relPath}: $cmd hidden behind Invoke-CommandSafe + ProgressMessage (${timeout}s)"
                [void]$issues.MEDIUM.Add($issue)
            }
            else {
                $issue = "MEDIUM: ${relPath}: $cmd with long timeout (${timeout}s), no visible progress"
                [void]$issues.MEDIUM.Add($issue)
            }
        }
    }

    # LOW: Scan for Start-Process timeout kill without /T
    if ($content -match 'Start-Process' -and $content -match 'WaitForExit' -and $content -match '\.Kill\(\)' -and $content -notmatch 'taskkill.*\/T') {
        $issue = "LOW: $relPath uses Kill() without taskkill /T for process tree"
        [void]$issues.LOW.Add($issue)
    }

    # MEDIUM: download function default timeout > 30s
    $downloadDefaults = [regex]::Matches($content, 'Invoke-VisibleFileDownload[\s\S]{0,300}\[int\]\$TimeoutSec\s*=\s*(\d+)')
    foreach ($dd in $downloadDefaults) {
        $ddSec = [int]$dd.Groups[1].Value
        if ($ddSec -gt 30) {
            $relPath3 = $file.FullName.Replace($RootDir, '').TrimStart('\', '/')
            $issue = "MEDIUM: ${relPath3}: Invoke-VisibleFileDownload default TimeoutSec=${ddSec}s > 30s"
            [void]$issues.MEDIUM.Add($issue)
        }
    }
    # MEDIUM: download call site timeout > 30s
    $downloadTimeout = [regex]::Matches($content, 'Invoke-VisibleFileDownload[\s\S]{0,200}-TimeoutSec\s+(\d+)')
    foreach ($dt in $downloadTimeout) {
        $dtSec = [int]$dt.Groups[1].Value
        if ($dtSec -gt 30) {
            $relPath3 = $file.FullName.Replace($RootDir, '').TrimStart('\', '/')
            $issue = "MEDIUM: ${relPath3}: Invoke-VisibleFileDownload call site timeout ${dtSec}s > 30s"
            [void]$issues.MEDIUM.Add($issue)
        }
    }

    # LOW: missing explicit TimeoutSec
    $missingTimeout = [regex]::Matches($content, 'Invoke-CommandSafe\s+-Command\s+"(\w[\w.]*)"(?![\s\S]{0,200}-TimeoutSec)')
    foreach ($mt in $missingTimeout) {
        $cmd2 = $mt.Groups[1].Value
        $relPath2 = $file.FullName.Replace($RootDir, '').TrimStart('\', '/')
        $issue = "LOW: ${relPath2}: $cmd2 using default 60s timeout"
        [void]$issues.LOW.Add($issue)
    }
}

Write-Host "========== HIGH severity (install commands hidden by Invoke-CommandSafe) =========="
if ($issues.HIGH.Count -eq 0) {
    Write-Host "  [PASS] None found" -ForegroundColor Green
} else {
    foreach ($i in $issues.HIGH) {
        Write-Host "  [FAIL] $i" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "========== MEDIUM severity (long timeouts without visible progress) =========="
if ($issues.MEDIUM.Count -eq 0) {
    Write-Host "  [PASS] None found" -ForegroundColor Green
} else {
    foreach ($i in $issues.MEDIUM) {
        Write-Host "  [WARN] $i" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "========== LOW severity (sub-optimal patterns) =========="
foreach ($i in $issues.LOW) {
    Write-Host "  [INFO] $i" -ForegroundColor DarkGray
}

Write-Host ""
$totalHigh = $issues.HIGH.Count
$totalMedium = $issues.MEDIUM.Count
$totalLow = $issues.LOW.Count
Write-Host "Summary: HIGH=$totalHigh, MEDIUM=$totalMedium, LOW=$totalLow"

if ($totalHigh -gt 0) {
    Write-Host "[FAIL] HIGH-severity issues found!" -ForegroundColor Red
    exit 1
}

Write-Host "[PASS] No HIGH-severity issues" -ForegroundColor Green
exit 0
