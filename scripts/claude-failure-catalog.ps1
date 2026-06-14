# ============================================================
# scripts/claude-failure-catalog.ps1 - failure case catalog validator
# Validates claude-install-failure-cases.json for completeness and correctness.
# ============================================================

param(
    [string]$DataFile = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$RootDir = Split-Path -Parent $PSScriptRoot
Set-Location $RootDir

if (-not $DataFile) {
    $DataFile = Join-Path $PSScriptRoot "data\claude-install-failure-cases.json"
}

$TotalChecks = 0
$FailedChecks = 0

function Assert {
    param([string]$Name, [scriptblock]$Condition)
    $script:TotalChecks++
    try {
        $result = & $Condition
        if (-not $result) {
            Write-Host ("[FAIL] {0}" -f $Name) -ForegroundColor Red
            $script:FailedChecks++
        } else {
            Write-Host ("[OK]   {0}" -f $Name) -ForegroundColor Green
        }
    } catch {
        Write-Host ("[FAIL] {0} - {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
        $script:FailedChecks++
    }
}

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "  Claude Install Failure Catalog Validator" -ForegroundColor Cyan
Write-Host "=============================================================="
Write-Host ("  Data file: {0}" -f $DataFile)
Write-Host ""

# 1. File exists and is valid JSON
Assert "Data file exists" { Test-Path $DataFile }

$data = $null
try {
    $data = Get-Content $DataFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert "Valid JSON parse" { $true }
} catch {
    Assert "Valid JSON parse" { $false }
    Write-Host "[ERROR] Cannot continue without valid JSON data" -ForegroundColor Red
    exit 1
}

# 2. cases array exists and non-empty
Assert "cases array exists" { $null -ne $data.cases }
Assert "cases array non-empty" { $data.cases.Count -gt 0 }

$cases = $data.cases
$ids = @{}

# 3. Validate each case
$validCategories = @(
    "系统与架构",
    "PowerShell/CMD/终端",
    "PATH与多安装冲突",
    "网络/代理/证书",
    "Node.js/npm/Registry",
    "文件系统/权限/安全软件",
    "Claude Code运行与诊断",
    "配置与状态",
    "安全与交付风险"
)

$validPlatforms = @("windows", "wsl", "linux", "cross-platform")
$validFixPolicies = @("AUTO_FIX_SAFE", "ASK_CONFIRM", "MANUAL_REQUIRED", "UNSUPPORTED", "NETWORK_BLOCKED", "SECURITY_RISK")

$requiredFields = @("id", "category", "platform", "symptom", "sampleErrors", "detection", "expectedDiagnosis", "fixPolicy", "safeRepairMock", "userMessage", "reportFields")

$caseIndex = 0
foreach ($case in $cases) {
    $caseIndex++
    $prefix = "Case[{0}] {1}" -f $caseIndex, $case.id

    # Required fields
    foreach ($field in $requiredFields) {
        Assert ("{0}: field '{1}' present" -f $prefix, $field) {
            $null -ne $case.$field
        }
    }

    # id uniqueness
    if ($case.id) {
        Assert ("{0}: id unique" -f $prefix) {
            if ($ids.ContainsKey($case.id)) {
                $false
            } else {
                $ids[$case.id] = $true
                $true
            }
        }
    }

    # category enum
    Assert ("{0}: category valid" -f $prefix) {
        $case.category -in $validCategories
    }

    # platform enum
    Assert ("{0}: platform valid" -f $prefix) {
        $case.platform -in $validPlatforms
    }

    # fixPolicy enum
    Assert ("{0}: fixPolicy valid" -f $prefix) {
        $case.fixPolicy -in $validFixPolicies
    }

    # sampleErrors non-empty
    Assert ("{0}: sampleErrors non-empty" -f $prefix) {
        $case.sampleErrors.Count -gt 0
    }

    # reportFields non-empty
    Assert ("{0}: reportFields non-empty" -f $prefix) {
        $case.reportFields.Count -gt 0
    }

    # expectedDiagnosis non-empty
    Assert ("{0}: expectedDiagnosis non-empty" -f $prefix) {
        $case.expectedDiagnosis -and $case.expectedDiagnosis.Length -gt 10
    }

    # userMessage non-empty
    Assert ("{0}: userMessage non-empty" -f $prefix) {
        $case.userMessage -and $case.userMessage.Length -gt 10
    }

    # AUTO_FIX_SAFE safety check: must not involve real uninstall, real delete, real system PATH modification, or real security software disable
    if ($case.fixPolicy -eq "AUTO_FIX_SAFE") {
        $dangerousKeywords = @("卸载Claude Code", "卸载Node.js", "删除用户软件", "删除用户程序", "删除系统", "禁用安全软件", "disable antivirus", "delete user software", "delete system32", "reg delete", "remove installed software")
        $combined = "$($case.safeRepairMock) $($case.userMessage) $($case.expectedDiagnosis)" -join " "
        $hasDanger = $false
        foreach ($kw in $dangerousKeywords) {
            if ($combined -match [regex]::Escape($kw)) {
                $hasDanger = $true
                break
            }
        }
        Assert ("{0}: AUTO_FIX_SAFE no dangerous operations" -f $prefix) { -not $hasDanger }
    }
}

# 4. Statistics validation
Assert "statistics.totalCases matches actual" {
    $data.statistics.totalCases -eq $cases.Count
}

# Category stats
$catStats = @{}
foreach ($case in $cases) {
    $prev = if ($catStats.ContainsKey($case.category)) { $catStats[$case.category] } else { 0 }
    $catStats[$case.category] = $prev + 1
}
Assert "statistics byCategory matches actual" {
    $ok = $true
    foreach ($cat in $catStats.Keys) {
        $statVal = $data.statistics.byCategory.$cat
        if ($statVal -ne $catStats[$cat]) {
            Write-Host ("  Category '{0}': stats={1} actual={2}" -f $cat, $statVal, $catStats[$cat]) -ForegroundColor Yellow
            $ok = $false
        }
    }
    $ok
}

# FixPolicy stats
$fixStats = @{}
foreach ($case in $cases) {
    $prevFix = if ($fixStats.ContainsKey($case.fixPolicy)) { $fixStats[$case.fixPolicy] } else { 0 }
    $fixStats[$case.fixPolicy] = $prevFix + 1
}
Assert "statistics byFixPolicy matches actual" {
    $ok = $true
    foreach ($fp in $fixStats.Keys) {
        $statVal = $data.statistics.byFixPolicy.$fp
        if ($statVal -ne $fixStats[$fp]) {
            Write-Host ("  FixPolicy '{0}': stats={1} actual={2}" -f $fp, $statVal, $fixStats[$fp]) -ForegroundColor Yellow
            $ok = $false
        }
    }
    $ok
}

# 5. Coverage summary
Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "  Coverage Summary" -ForegroundColor Cyan
Write-Host "=============================================================="
Write-Host ("  Total cases:          {0}" -f $cases.Count)
Write-Host ("  Total checks:         {0}" -f $TotalChecks)
Write-Host ("  Failed checks:        {0}" -f $FailedChecks)
Write-Host ""
Write-Host "  By fix policy:"
foreach ($fp in @("AUTO_FIX_SAFE","ASK_CONFIRM","MANUAL_REQUIRED","UNSUPPORTED","NETWORK_BLOCKED","SECURITY_RISK")) {
    $count = if ($fixStats.ContainsKey($fp)) { $fixStats[$fp] } else { 0 }
    Write-Host ("    {0,-20}: {1}" -f $fp, $count)
}
Write-Host ""
Write-Host "  By category:"
foreach ($cat in ($catStats.Keys | Sort-Object)) {
    Write-Host ("    {0,-30}: {1}" -f $cat, $catStats[$cat])
}
Write-Host ""
Write-Host "  By platform:"
$platStats = @{}
foreach ($case in $cases) {
    $prevPlat = if ($platStats.ContainsKey($case.platform)) { $platStats[$case.platform] } else { 0 }
    $platStats[$case.platform] = $prevPlat + 1
}
foreach ($p in ($platStats.Keys | Sort-Object)) {
    Write-Host ("    {0,-20}: {1}" -f $p, $platStats[$p])
}

if ($FailedChecks -gt 0) {
    Write-Host ""
    Write-Host ("[claude-failure-catalog] FAILED: {0}/{1} checks" -f $FailedChecks, $TotalChecks) -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host ("[claude-failure-catalog] PASSED: {0} checks" -f $TotalChecks) -ForegroundColor Green
exit 0
