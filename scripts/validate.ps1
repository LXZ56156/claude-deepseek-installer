# ============================================================
# scripts/validate.ps1 - unified validation entry
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Smoke
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Full
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode Release
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate.ps1 -Mode All
#
# Notes:
#   This script only orchestrates existing validation tools.
#   Flows that write Claude config must use CCDI_TEST_MODE + CCDI_TEST_USERPROFILE.
# ============================================================

param(
    [ValidateSet("Smoke", "Full", "Release", "All")]
    [string]$Mode = "Smoke",

    [string]$Version = "1.3.2",

    [switch]$SkipPwsh,

    [switch]$RequireClean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 显式导入核心模块（部分环境的模块自动加载不可用）
Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue

$RootDir = Split-Path -Parent $PSScriptRoot
Set-Location $RootDir

$script:StepCount = 0
$script:Failures = New-Object System.Collections.ArrayList

# git 可用性检查
$gitAvailable = $null -ne (Get-Command "git" -ErrorAction SilentlyContinue)
if (-not $gitAvailable) {
    Write-Host "[validate] ERROR: git is not available. Validation cannot proceed." -ForegroundColor Red
    exit 1
}

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
    Write-Host ""
    Write-Host ("[validate] {0}. {1}" -f $script:StepCount, $Name) -ForegroundColor Cyan
    $started = Get-Date

    try {
        & $ScriptBlock
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

function Invoke-PowerShellScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$Arguments = @()
    )

    Invoke-ExternalCommand -FileName "powershell.exe" -Arguments (@(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $FilePath
    ) + $Arguments)
}

function Invoke-CoreSandboxFlow {
    $sandbox = Join-Path $RootDir ".sandbox\validate-core"
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
        )
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "repair-deps.ps1") -Arguments @("-TestSafe")
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "Start-Here.ps1") -Arguments @("-FixDeps", "-TestSafe")
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "doctor.ps1") -Arguments @(
            "-ShareSafe", "-SkipApiTest", "-NoOpenReport"
        )
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
        Where-Object { $_.FullName -notmatch '\\.git|\\.sandbox|\\backup|\\logs|\\reports|\\release|\\node_modules' } |
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
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "scripts\check.ps1")
    })
    $pwshCommand = Get-Command "pwsh" -ErrorAction SilentlyContinue
    if ((-not $SkipPwsh) -and $pwshCommand) {
        Invoke-ValidationStep -Name "scripts/check.ps1 (pwsh)" -ScriptBlock ([scriptblock]{
            Invoke-ExternalCommand -FileName "pwsh" -Arguments @(
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $RootDir "scripts\check.ps1")
            )
        })
    }
}

function Invoke-FullValidation {
    Write-ValidationHeader "Full source validation"

    Invoke-SmokeValidation
    Invoke-ValidationStep -Name "PowerShell full AST parse" -ScriptBlock ([scriptblock]{ Invoke-ParseCheck })
    Invoke-ValidationStep -Name "scripts/ux-check.ps1" -ScriptBlock ([scriptblock]{
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "scripts\ux-check.ps1")
    })
    Invoke-ValidationStep -Name "Core TestSafe sandbox flow" -ScriptBlock ([scriptblock]{ Invoke-CoreSandboxFlow })
}

function Invoke-ReleaseValidation {
    Write-ValidationHeader "Release validation"

    Invoke-ValidationStep -Name "package release ZIP" -ScriptBlock ([scriptblock]{
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "scripts\package-release.ps1") -Arguments @("-Version", $Version)
    })
    Invoke-ValidationStep -Name "release ZIP user simulation" -ScriptBlock ([scriptblock]{
        Invoke-PowerShellScript -FilePath (Join-Path $RootDir "scripts\simulate-user-release.ps1") -Arguments @("-Version", $Version)
    })
}

$beforeSettings = Get-RealSettingsSnapshot
Write-Host "[validate] Mode=$Mode Version=$Version Branch=$(git branch --show-current) RequireClean=$requireCleanForRun"
Write-Host "[validate] Real settings baseline: Exists=$($beforeSettings.Exists) Length=$($beforeSettings.Length) SHA256=$($beforeSettings.SHA256)"

# RequireClean 下的 git status 检查（在验证步骤开始前运行）
if ($requireCleanForRun) {
    Invoke-ValidationStep -Name "git status clean" -ScriptBlock {
        $status = git status --short
        if ($status) {
            $msg = "Working tree is not clean:`n" + ($status -join "`n")
            throw $msg
        }
    }
}

switch ($Mode) {
    "Smoke" {
        Invoke-SmokeValidation
    }
    "Full" {
        Invoke-FullValidation
    }
    "Release" {
        Invoke-ReleaseValidation
    }
    "All" {
        Invoke-FullValidation
        Invoke-ReleaseValidation
    }
}

$afterSettings = Get-RealSettingsSnapshot
Invoke-ValidationStep -Name "real settings.json unchanged" -ScriptBlock ([scriptblock]{
    Assert-RealSettingsUnchanged -Before $beforeSettings -After $afterSettings
})

# 结束前 final git status clean（兜底：防止验证步骤意外生成未被 .gitignore 覆盖的文件）
if ($requireCleanForRun) {
    Invoke-ValidationStep -Name "final git status clean" -ScriptBlock {
        $status = git status --short
        if ($status) {
            $msg = "Working tree is not clean after validation:`n" + ($status -join "`n")
            throw $msg
        }
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
    Write-Host "  Failed steps:"
    foreach ($failure in $script:Failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    Write-Host "==============================================================" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Green
Write-Host "  Validation PASSED: $($script:StepCount) step(s)" -ForegroundColor Green
Write-Host "==============================================================" -ForegroundColor Green
exit 0
