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

    $relPath = $file.FullName.Replace($RootDir, '').TrimStart('\', '/')

    # ================================================================
    # Invoke-CommandSafe 调用扫描
    # ================================================================
    $invokeCalls = [regex]::Matches($content, 'Invoke-CommandSafe\s+-Command\s+"(\w[\w.]*)"\s*(?:-Arguments\s+@\([\s\S]*?\)\s*)?-TimeoutSec\s+(\d+)')

    foreach ($match in $invokeCalls) {
        $cmd = $match.Groups[1].Value
        $timeout = [int]$match.Groups[2].Value
        $surroundingText = $content.Substring([Math]::Max(0, $match.Index - 100), [Math]::Min(400, $content.Length - [Math]::Max(0, $match.Index - 100)))

        # ---- HIGH: long-running install commands still using Invoke-CommandSafe ----
        foreach ($risk in $highRiskPatterns) {
            if ($surroundingText -match $risk.Pattern) {
                $issue = "HIGH: $($risk.Name) via Invoke-CommandSafe (${timeout}s) in $relPath"
                [void]$issues.HIGH.Add($issue)
            }
        }

        # ---- HIGH: wsl + TimeoutSec >= 300 + Invoke-CommandSafe ----
        if ($cmd -eq "wsl" -and $timeout -ge 300) {
            $issue = "HIGH: wsl execution via Invoke-CommandSafe with ${timeout}s timeout in $relPath"
            [void]$issues.HIGH.Add($issue)
        }

        # ---- HIGH: code --install-extension + Invoke-CommandSafe + TimeoutSec >= 60 ----
        if ($surroundingText -match 'code[\s\S]{0,100}--install-extension' -and $timeout -ge 60) {
            $issue = "HIGH: code --install-extension via Invoke-CommandSafe (${timeout}s) in $relPath"
            [void]$issues.HIGH.Add($issue)
        }

        # ---- MEDIUM: timeout >= 120 with ProgressMessage ----
        if ($timeout -ge 120) {
            if ($surroundingText -match 'ProgressMessage') {
                if ($surroundingText -match '仍在') {
                    $issue = "MEDIUM: ${relPath}: $cmd hidden behind Invoke-CommandSafe + ProgressMessage '仍在...' (${timeout}s)"
                } else {
                    $issue = "MEDIUM: ${relPath}: $cmd hidden behind Invoke-CommandSafe + ProgressMessage (${timeout}s)"
                }
                [void]$issues.MEDIUM.Add($issue)
            }
            else {
                $issue = "MEDIUM: ${relPath}: $cmd with long timeout (${timeout}s), no visible progress"
                [void]$issues.MEDIUM.Add($issue)
            }
        }
    }

    # ---- MEDIUM/LOW: npm prefix -g without explicit TimeoutSec <= 8 ----
    # Match the full Invoke-CommandSafe call covering npm prefix -g, extending past
    # the closing paren to capture -TimeoutSec if present.
    $npmPrefixCalls = [regex]::Matches($content, 'Invoke-CommandSafe\s+-Command\s+"npm"[\s\S]{0,400}?"-g"\s*\)[\s\S]{0,80}?-TimeoutSec\s+(\d+)')
    foreach ($np in $npmPrefixCalls) {
        $npFull = $np.Groups[0].Value
        if ($npFull -match '"prefix"') {
            $npSec = [int]$np.Groups[1].Value
            if ($npSec -gt 8) {
                $issue = "MEDIUM: ${relPath}: npm prefix -g TimeoutSec=${npSec}s should be <= 8s"
                [void]$issues.MEDIUM.Add($issue)
            }
        }
    }
    # Detect npm prefix -g call missing TimeoutSec entirely (uses default 60s)
    # We do this by finding npm+prefix+"-g" calls and checking if the surrounding
    # context (up to 100 chars past the close-paren) lacks -TimeoutSec.
    $npmNoTimeoutMatches = [regex]::Matches($content, 'Invoke-CommandSafe\s+-Command\s+"npm"[\s\S]{0,400}?"-g"\s*\)')
    foreach ($npnt in $npmNoTimeoutMatches) {
        $npntFull = $npnt.Groups[0].Value
        if ($npntFull -match '"prefix"' -and $npntFull -notmatch '-TimeoutSec') {
            # Verify this isn't a case where -TimeoutSec is right after the paren
            $npntIdx = $npnt.Index
            $trailing = $content.Substring($npntIdx, [Math]::Min(120, $content.Length - $npntIdx))
            if ($trailing -notmatch '-TimeoutSec\s+\d+') {
                $issue = "MEDIUM: ${relPath}: npm prefix -g has no explicit TimeoutSec (uses default 60s)"
                [void]$issues.MEDIUM.Add($issue)
            }
        }
    }

    # ---- LOW: missing explicit TimeoutSec ----
    $missingTimeout = [regex]::Matches($content, 'Invoke-CommandSafe\s+-Command\s+"(\w[\w.]*)"(?![\s\S]{0,200}-TimeoutSec)')
    foreach ($mt in $missingTimeout) {
        $cmd2 = $mt.Groups[1].Value
        $issue = "LOW: ${relPath}: $cmd2 using default 60s timeout"
        [void]$issues.LOW.Add($issue)
    }

    # ---- LOW: Start-Process timeout kill without /T ----
    if ($content -match 'Start-Process' -and $content -match 'WaitForExit' -and $content -match '\.Kill\(\)' -and $content -notmatch 'taskkill.*\/T') {
        $issue = "LOW: $relPath uses Kill() without taskkill /T for process tree"
        [void]$issues.LOW.Add($issue)
    }

    # ---- MEDIUM: download function default timeout > 30s ----
    $downloadDefaults = [regex]::Matches($content, 'Invoke-VisibleFileDownload[\s\S]{0,300}\[int\]\$TimeoutSec\s*=\s*(\d+)')
    foreach ($dd in $downloadDefaults) {
        $ddSec = [int]$dd.Groups[1].Value
        if ($ddSec -gt 30) {
            $issue = "MEDIUM: ${relPath}: Invoke-VisibleFileDownload default TimeoutSec=${ddSec}s > 30s"
            [void]$issues.MEDIUM.Add($issue)
        }
    }
    # ---- MEDIUM: download call site timeout > 30s ----
    $downloadTimeout = [regex]::Matches($content, 'Invoke-VisibleFileDownload[\s\S]{0,200}-TimeoutSec\s+(\d+)')
    foreach ($dt in $downloadTimeout) {
        $dtSec = [int]$dt.Groups[1].Value
        if ($dtSec -gt 30) {
            $issue = "MEDIUM: ${relPath}: Invoke-VisibleFileDownload call site timeout ${dtSec}s > 30s"
            [void]$issues.MEDIUM.Add($issue)
        }
    }
}

# ================================================================
# Start-Here.ps1 结构检查
# ================================================================
$startHerePath = Join-Path $RootDir "Start-Here.ps1"
if (Test-Path $startHerePath) {
    $startHereText = Get-Content $startHerePath -Raw -Encoding UTF8

    # Rule 6: Must have Write-CheckProgress or equivalent progress function
    if ($startHereText -notmatch 'function Write-CheckProgress') {
        $issue = "MEDIUM: Start-Here.ps1: missing Write-CheckProgress function (no per-check progress indicators)"
        [void]$issues.MEDIUM.Add($issue)
    }

    # Rule 7: Must show log path early (before disclaimer or main menu)
    if ($startHereText -notmatch '本次运行日志.*Get-LogFilePath') {
        $issue = "MEDIUM: Start-Here.ps1: does not show log path early (missing '本次运行日志')"
        [void]$issues.MEDIUM.Add($issue)
    }
    if ($startHereText -notmatch '如果窗口异常关闭，可把此文件发给技术支持') {
        $issue = "MEDIUM: Start-Here.ps1: missing early log path guidance text"
        [void]$issues.MEDIUM.Add($issue)
    }

    # Rule 9: WSL method B removed (no wsl + Invoke-CommandSafe + TimeoutSec 600 in Start-WslSetup)
    if ($startHereText -match 'Start-WslSetup[\s\S]{0,3000}Invoke-CommandSafe[\s\S]{0,200}wsl') {
        $issue = "HIGH: Start-Here.ps1: Start-WslSetup still uses Invoke-CommandSafe for wsl execution"
        [void]$issues.HIGH.Add($issue)
    }
    if ($startHereText -match 'Start-WslSetup[\s\S]{0,3000}TimeoutSec\s+600') {
        $issue = "HIGH: Start-Here.ps1: Start-WslSetup still has 600s timeout for wsl"
        [void]$issues.HIGH.Add($issue)
    }

    # Check no "方式 B" in WSL setup (prevent confusing advanced users with Windows-side WSL call)
    if ($startHereText -match '方式\s*B') {
        $issue = "LOW: Start-Here.ps1: contains '方式 B' reference (may be in WSL context, should be removed)"
        [void]$issues.LOW.Add($issue)
    }
}

# ================================================================
# repair-deps.ps1 检查
# ================================================================
$repairDepsPath = Join-Path $RootDir "repair-deps.ps1"
if (Test-Path $repairDepsPath) {
    $repairDepsText = Get-Content $repairDepsPath -Raw -Encoding UTF8

    # Rule 5: npm prefix -g must have TimeoutSec 8
    $rpmNoTimeout = [regex]::Match($repairDepsText, 'Invoke-CommandSafe\s+-Command\s+"npm"[\s\S]{0,400}?"-g"\s*\)')
    if ($rpmNoTimeout.Success) {
        $rpmFull = $rpmNoTimeout.Groups[0].Value
        if ($rpmFull -match '"prefix"' -and $rpmFull -notmatch '-TimeoutSec') {
            $rpmIdx = $rpmNoTimeout.Index
            $rpmTrailing = $repairDepsText.Substring($rpmIdx, [Math]::Min(120, $repairDepsText.Length - $rpmIdx))
            if ($rpmTrailing -notmatch '-TimeoutSec\s+\d+') {
                $issue = "MEDIUM: repair-deps.ps1: npm prefix -g missing explicit TimeoutSec"
                [void]$issues.MEDIUM.Add($issue)
            }
        }
    }
}

# ================================================================
# 输出
# ================================================================
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
if ($issues.LOW.Count -eq 0) {
    Write-Host "  [PASS] None found" -ForegroundColor Green
} else {
    foreach ($i in $issues.LOW) {
        Write-Host "  [INFO] $i" -ForegroundColor DarkGray
    }
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
