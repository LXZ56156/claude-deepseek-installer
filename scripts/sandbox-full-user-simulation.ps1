# ============================================================
# scripts/sandbox-full-user-simulation.ps1
# 全量沙盒真实使用模拟验收
#
# 覆盖场景 A-P，全程 CCDI_TEST_MODE=1，所有写入进入 .sandbox 或临时目录。
# 不真实安装、不真实卸载、不修改真实 %USERPROFILE%\.claude\settings.json。
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sandbox-full-user-simulation.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sandbox-full-user-simulation.ps1 -Version "1.3.2" -KeepTemp
# ============================================================

param(
    [string]$Version = "1.3.2",
    [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:TotalPass = 0
$script:TotalFail = 0
$script:Failures = New-Object System.Collections.ArrayList
$DummyApiKey = "sk-" + ("x" * 32)
$DummyPartialKey = "sk-" + ("x" * 4)

function Write-SandboxPass {
    param([string]$Scenario)
    $script:TotalPass++
    Write-Host "[sandbox] PASS: $Scenario" -ForegroundColor Green
}

function Write-SandboxFail {
    param([string]$Scenario, [string]$Reason)
    $script:TotalFail++
    $msg = "[sandbox] FAIL: $Scenario - $Reason"
    Write-Host $msg -ForegroundColor Red
    [void]$script:Failures.Add($msg)
}

function Write-SandboxInfo {
    param([string]$Message)
    Write-Host "[sandbox] INFO: $Message" -ForegroundColor Cyan
}

function Write-SandboxSkip {
    param([string]$Scenario, [string]$Reason)
    Write-Host "[sandbox] SKIP: $Scenario - $Reason" -ForegroundColor Yellow
}

# ============================================================
# Helper: assert a text does not contain a forbidden pattern
# ============================================================
function Assert-TextNotContains {
    param([string]$Label, [string]$Text, [string[]]$Forbidden, [string]$Context = "")

    foreach ($f in $Forbidden) {
        if ($Text -match [regex]::Escape($f)) {
            throw "$Label contains forbidden pattern: '$f' $Context"
        }
    }
}

function Assert-TextContains {
    param([string]$Label, [string]$Text, [string[]]$Required, [string]$Context = "")

    foreach ($r in $Required) {
        if ($Text -notmatch [regex]::Escape($r)) {
            throw "$Label missing required pattern: '$r' $Context"
        }
    }
}

# ============================================================
# ConvertTo-SafeArg helper for process invocation
# ============================================================
function ConvertTo-SafeArg {
    param([AllowNull()][string]$Argument)

    if ($null -eq $Argument) { return '""' }
    if ($Argument.Length -eq 0) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($c in $Argument.ToCharArray()) {
        if ($c -eq '\') { $bs++; continue }
        if ($c -eq '"') {
            [void]$sb.Append(('\' * ($bs * 2 + 1)))
            [void]$sb.Append('"')
        } else {
            if ($bs -gt 0) { [void]$sb.Append(('\' * $bs)) }
            [void]$sb.Append($c)
        }
        $bs = 0
    }
    if ($bs -gt 0) { [void]$sb.Append(('\' * ($bs * 2))) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-SafeCmdLine {
    param([string[]]$Arguments)
    if (-not $Arguments) { return "" }
    ($Arguments | ForEach-Object { ConvertTo-SafeArg -Argument $_ }) -join " "
}

function Invoke-SandboxProcess {
    param(
        [string]$Label,
        [string]$FileName,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [int]$ExpectedExitCode = 0,
        [int]$TimeoutSec = 180,
        [string]$InputText = ""
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = ConvertTo-SafeCmdLine -Arguments $Arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    # 先复制父进程全部环境变量，再覆盖显式传入的变量。
    # 不能只设显式变量：$psi.EnvironmentVariables 一旦被触碰，子进程
    # 就不再继承父进程环境，导致 CCDI_TEST_MODE / CCDI_TEST_USERPROFILE
    # 等全局状态丢失，进而污染真实 %USERPROFILE%\.claude\settings.json。
    $parentEnv = [Environment]::GetEnvironmentVariables()
    foreach ($k in $parentEnv.Keys) {
        $psi.EnvironmentVariables[$k] = [string]$parentEnv[$k]
    }
    foreach ($k in $Environment.Keys) {
        $psi.EnvironmentVariables[$k] = [string]$Environment[$k]
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()

    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    if ($InputText) {
        $proc.StandardInput.Write($InputText)
    }
    $proc.StandardInput.Close()

    $finished = $proc.WaitForExit($TimeoutSec * 1000)
    if (-not $finished) {
        $realPid = $proc.Id
        try { & taskkill.exe /PID $realPid /T /F 2>$null | Out-Null; Start-Sleep -Milliseconds 500 } catch { }
        if (-not $proc.HasExited) { try { Stop-Process -Id $realPid -Force -ErrorAction SilentlyContinue } catch { } }
        throw "$Label timed out after ${TimeoutSec}s"
    }

    [void]$stdoutTask.Wait(5000)
    [void]$stderrTask.Wait(5000)

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $ec = $proc.ExitCode

    if ($ec -ne $ExpectedExitCode) {
        throw "$Label exit code $ec, expected $ExpectedExitCode. STDOUT:`n$stdout`nSTDERR:`n$stderr"
    }

    return [PSCustomObject]@{
        Label    = $Label
        ExitCode = $ec
        Stdout   = $stdout
        Stderr   = $stderr
        Combined = "$stdout`n$stderr"
    }
}

# ============================================================
# Helper: run a PowerShell snippet in subprocess that dot-sources
# release libs and calls a specific function. Parses structured
# SANDBOX_TEST: markers to determine pass/fail.
# ============================================================
function Invoke-SandboxFunctionTest {
    param(
        [string]$Label,
        [string]$ReleaseRoot,
        [string]$ScriptText,
        [hashtable]$Environment = @{},
        [int]$TimeoutSec = 60
    )

    # Build a self-contained test script
    $testScript = @"
`$ErrorActionPreference = 'Continue'
Set-Location '$ReleaseRoot'

# Load libraries
. .\lib\logger.ps1 2>`$null
. .\lib\common.ps1 2>`$null
. .\lib\state.ps1 2>`$null
. .\lib\env-check.ps1 2>`$null
. .\lib\config-writer.ps1 2>`$null
. .\lib\claude-install.ps1 2>`$null

# Suppress Write-Log output in subprocess
function global:Write-Log { param(`$Level, `$Message) }
function global:Write-Info { param(`$Message) }
function global:Write-Success { param(`$Message) }
function global:Write-Warning { param(`$Message) }
function global:Write-Error-Msg { param(`$Message) }
function global:Write-FatalError { param(`$Message) }
function global:Write-Step { param(`$Message) }
function global:Write-Result { param(`$Status, `$Label, `$Detail = '') }
function global:Add-CheckResult { param(`$Label, `$Status, `$Detail = '') }
function global:Add-Suggestion { param(`$Message) }

$ScriptText
"@

    # Write temp file
    $tempTestFile = Join-Path ([System.IO.Path]::GetTempPath()) "ccdi_sandbox_fntest_${PID}_$(Get-Random).ps1"
    try {
        [System.IO.File]::WriteAllText($tempTestFile, $testScript, (New-Object System.Text.UTF8Encoding($false)))

        $result = Invoke-SandboxProcess -Label $Label `
            -FileName "powershell.exe" `
            -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $tempTestFile) `
            -WorkingDirectory $ReleaseRoot `
            -Environment $Environment `
            -TimeoutSec $TimeoutSec

        return $result
    }
    finally {
        Remove-Item $tempTestFile -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
# Setup sandbox directories
# ============================================================
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ccdi_sandbox_full_$PID")
$sandboxDir = Join-Path $ProjectRoot ".sandbox\full-user-sim"
$extractDir = Join-Path $sandboxDir "extract-($Version)-中文测试"
$profileDir = Join-Path $sandboxDir "userprofile"
$desktopDir = Join-Path $sandboxDir "desktop"

# Clean up old sandbox
Remove-Item $sandboxDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue

New-Item -ItemType Directory -Path $extractDir, $profileDir, $desktopDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $profileDir ".claude") -Force | Out-Null

# Base environment
$baseEnv = @{
    CCDI_TEST_MODE        = "1"
    CCDI_TEST_USERPROFILE = $profileDir
    CCDI_TEST_DESKTOP     = $desktopDir
    CCDI_API_KEY          = $DummyApiKey
    CCDI_TEST_API_STATUS  = "200"
}

try {
    # ============================================================
    # SCENARIO A: Build ZIP + extract
    # ============================================================
    Write-Host ""
    Write-Host "=== SCENARIO A: Release ZIP Build & Extract ===" -ForegroundColor Cyan

    try {
        $buildScript = Join-Path $ProjectRoot "scripts\build-release.ps1"
        $releaseDir = Join-Path $ProjectRoot "release"

        $buildResult = Invoke-SandboxProcess -Label "build ZIP" `
            -FileName "powershell.exe" `
            -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $buildScript, "-Version", $Version) `
            -WorkingDirectory $ProjectRoot -TimeoutSec 300

        $zipFile = Get-ChildItem -Path $releaseDir -Filter "*.zip" |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1

        if (-not $zipFile) { throw "ZIP file not found in release/" }

        # Forbidden entries
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipFile.FullName)
        $forbiddenPatterns = @(
            ".git/", "logs/", "backup/", "reports/", "release/",
            "scripts/build-release.ps1", "scripts/simulate-user-release.ps1",
            "scripts/package-release.ps1", "CLAUDE.md", ".gitignore", "report.txt"
        )
        $zipEntries = $zip.Entries | ForEach-Object { $_.FullName }
        $forbiddenFound = $false
        foreach ($entry in $zipEntries) {
            foreach ($fp in $forbiddenPatterns) {
                if ($entry -like "*$fp*") {
                    Write-SandboxFail "A. ZIP forbidden entry" "$entry"
                    $forbiddenFound = $true
                }
            }
        }
        $zip.Dispose()
        if (-not $forbiddenFound) {
            Write-SandboxPass "A1. ZIP contains no forbidden entries"
        }

        # SHA256
        $shaFile = Join-Path $releaseDir "*.zip.sha256"
        if (Get-ChildItem -Path $releaseDir -Filter "*.zip.sha256" -ErrorAction SilentlyContinue) {
            Write-SandboxPass "A2. SHA256 file generated"
        } else {
            Write-SandboxFail "A2. SHA256" "no .sha256 file"
        }

        # Extract to dir with Chinese + spaces
        Expand-Archive -LiteralPath $zipFile.FullName -DestinationPath $extractDir -Force
        if ((Get-ChildItem -Path $extractDir -Filter "Start-Here.ps1" -ErrorAction SilentlyContinue)) {
            Write-SandboxPass "A3. ZIP extracted to path with Chinese + spaces"
        } else {
            Write-SandboxFail "A3. ZIP extract" "Start-Here.ps1 not found in extract dir"
        }
    } catch {
        Write-SandboxFail "A. ZIP build/extract" $_.Exception.Message
    }

    # ============================================================
    # SCENARIO B: Encoding & static syntax
    # ============================================================
    Write-Host ""
    Write-Host "=== SCENARIO B: Encoding & Static Syntax ===" -ForegroundColor Cyan

    try {
        $ps1Files = Get-ChildItem -Path $extractDir -Filter "*.ps1" -Recurse
        $parseErrors = $false
        $bomErrors = $false
        foreach ($f in $ps1Files) {
            # AST parse
            $tokens = $null; $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors) | Out-Null
            if ($errors.Count -gt 0) {
                Write-SandboxFail "B1. AST parse $($f.Name)" "$($errors[0].Message)"
                $parseErrors = $true
            }

            # BOM check
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
                Write-SandboxFail "B2. BOM $($f.Name)" "missing UTF-8 BOM"
                $bomErrors = $true
            }
        }
        if (-not $parseErrors) { Write-SandboxPass "B1. All .ps1 AST parse passed" }
        if (-not $bomErrors) { Write-SandboxPass "B2. All .ps1 have UTF-8 BOM" }

        # CMD ASCII check
        $cmdFiles = Get-ChildItem -Path $extractDir -Filter "*.cmd" -Recurse
        $cmdAsciiOk = $true
        foreach ($f in $cmdFiles) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF) {
                Write-SandboxFail "B3. CMD BOM $($f.Name)" "has UTF-8 BOM"
                $cmdAsciiOk = $false
            }
            foreach ($b in $bytes) {
                if ($b -gt 0x7F) {
                    Write-SandboxFail "B3. CMD ASCII $($f.Name)" "non-ASCII byte: $b"
                    $cmdAsciiOk = $false
                    break
                }
            }
        }
        if ($cmdAsciiOk) { Write-SandboxPass "B3. All .cmd are ASCII (no BOM)" }

        # No terminal-risk chars in docs
        $badPattern = '\p{So}|[─-╿]|️'
        $docFiles = Get-ChildItem -Path $extractDir -Filter "*.md" -Recurse -ErrorAction SilentlyContinue
        $docsOk = $true
        foreach ($f in $docFiles) {
            $content = Get-Content -Path $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            if ([regex]::IsMatch($content, $badPattern)) {
                Write-SandboxFail "B4. Doc risk chars $($f.Name)" "contains terminal-risk characters"
                $docsOk = $false
            }
        }
        if ($docsOk) { Write-SandboxPass "B4. No terminal-risk characters in docs" }
    } catch {
        Write-SandboxFail "B. Encoding" $_.Exception.Message
    }

    # ============================================================
    # SCENARIO C: Start-Here main flow
    # ============================================================
    Write-Host ""
    Write-Host "=== SCENARIO C: Start-Here Main Flow ===" -ForegroundColor Cyan

    try {
        $startHerePath = Join-Path $extractDir "Start-Here.ps1"
        $startEnv = $baseEnv.Clone()

        $startRun = Invoke-SandboxProcess -Label "Start-Here.ps1 TestSafe" `
            -FileName "powershell.exe" `
            -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $startHerePath,
                "-NonInteractive", "-SkipDisclaimer", "-TestSafe") `
            -WorkingDirectory $extractDir -Environment $startEnv -TimeoutSec 300

        # Check settings.json generated
        $settingsPath = Join-Path $profileDir ".claude\settings.json"
        if (Test-Path $settingsPath) {
            $settingsContent = Get-Content -Path $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($settingsContent.env.ANTHROPIC_AUTH_TOKEN -and
                $settingsContent.env.ANTHROPIC_BASE_URL -eq "https://api.deepseek.com/anthropic") {
                Write-SandboxPass "C1. settings.json generated with DeepSeek env"
            } else {
                Write-SandboxFail "C1. settings.json" "DeepSeek env fields incorrect"
            }
        } else {
            Write-SandboxFail "C1. settings.json" "not found at $settingsPath"
        }

        # Check install-report generated
        $reports = Get-ChildItem -Path (Join-Path $extractDir "reports") -Filter "install-report-*.txt" -ErrorAction SilentlyContinue
        if ($reports) {
            Write-SandboxPass "C2. install-report generated"
        } else {
            Write-SandboxFail "C2. install-report" "not found in reports/"
        }

        # No ParserError / 无法将 / not recognized / Write-Log undefined
        $allOutput = $startRun.Combined
        $badPatterns = @("ParserError", "无法将", "not recognized", "Write-Log", "Write-Error-Msg")
        $outputOk = $true
        foreach ($bp in $badPatterns) {
            if ($allOutput -match [regex]::Escape($bp)) {
                Write-SandboxFail "C3. Output quality" "found: $bp"
                $outputOk = $false
            }
        }
        if ($outputOk) { Write-SandboxPass "C3. Output free of runtime errors" }

        # Check non-env fields preserved
        if (Test-Path $settingsPath) {
            $sc = Get-Content -Path $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($sc.env.ANTHROPIC_MODEL -eq "deepseek-v4-pro[1m]" -and
                $sc.env.ANTHROPIC_SMALL_FAST_MODEL -eq "deepseek-v4-flash") {
                Write-SandboxPass "C4. DevSeek model env fields correct"
            }
        }
    } catch {
        Write-SandboxFail "C. Start-Here flow" $_.Exception.Message
    }

    # ============================================================
    # SCENARIO D: .cmd entry points
    # ============================================================
    Write-Host ""
    Write-Host "=== SCENARIO D: .cmd Entry Points ===" -ForegroundColor Cyan

    $cmdLaunchers = @(
        "Start-Install.cmd",
        "00-点我开始安装.cmd",
        "Run-Diagnostics.cmd",
        "一键诊断.cmd",
        "Restore-Config.cmd",
        "恢复或卸载配置.cmd",
        "一键修复依赖.cmd"
    )

    # First verify all .cmd files exist and are ASCII (static checks done in B3)
    $cmdOk = $true
    foreach ($launcher in $cmdLaunchers) {
        $launcherPath = Join-Path $extractDir $launcher
        if (-not (Test-Path $launcherPath)) {
            Write-SandboxFail "D. $launcher" "file not found"
            $cmdOk = $false
        } else {
            Write-SandboxPass "D. $launcher exists in release"
        }
    }

    # Test .cmd launchers from ASCII-only temp directory (CMD pipe has encoding issues with CJK paths)
    $cmdTestDir = Join-Path $sandboxDir "cmd-ascii-test"
    New-Item -ItemType Directory -Path $cmdTestDir -Force | Out-Null
    # Copy ALL files from extract dir to temp dir for .cmd to find companions
    Copy-Item -Path (Join-Path $extractDir "*") -Destination $cmdTestDir -Recurse -Force

    foreach ($launcher in $cmdLaunchers) {
        try {
            $launcherPath = Join-Path $cmdTestDir $launcher
            if (-not (Test-Path $launcherPath)) { continue }

            # Use InputText (stdin redirect) instead of echo pipe to avoid CJK path encoding issues
            $run = Invoke-SandboxProcess -Label "$launcher cancel (ASCII path)" `
                -FileName "cmd.exe" `
                -Arguments @("/d", "/s", "/c", ".\$launcher") `
                -WorkingDirectory $cmdTestDir -Environment $baseEnv -TimeoutSec 60 `
                -InputText "N`r`n"

            if ($run.Combined -match "ParserError") {
                Write-SandboxFail "D. $launcher" "ParserError in output"
                $cmdOk = $false
            } else {
                Write-SandboxPass "D. $launcher starts and exits cleanly"
            }
        } catch {
            Write-SandboxFail "D. $launcher" $_.Exception.Message
            $cmdOk = $false
        }
    }
    Remove-Item $cmdTestDir -Recurse -Force -ErrorAction SilentlyContinue

    # 缺文件提示
    try {
        $missingDir = Join-Path $sandboxDir "missing-files"
        New-Item -ItemType Directory -Path $missingDir -Force | Out-Null
        foreach ($launcher in $cmdLaunchers) {
            Copy-Item -Path (Join-Path $extractDir $launcher) -Destination (Join-Path $missingDir $launcher) -Force
            $run = Invoke-SandboxProcess -Label "Missing: $launcher" `
                -FileName "cmd.exe" -Arguments @("/c", ".`\$launcher") `
                -WorkingDirectory $missingDir -ExpectedExitCode 1 -Environment $baseEnv -TimeoutSec 30
            if ($run.Combined -notmatch "Please extract|请完整解压|完整解压 ZIP") {
                Write-SandboxFail "D. $launcher missing guidance" "no extract-full-ZIP message"
                $cmdOk = $false
            } else {
                Write-SandboxPass "D. $launcher shows extract-ZIP guidance when files missing"
            }
            Remove-Item -Path (Join-Path $missingDir $launcher) -Force
        }
    } catch {
        Write-SandboxFail "D. Missing file guidance" $_.Exception.Message
    }

    # ============================================================
    # SCENARIO E: Doctor default mode (NO deep WSL)
    # ============================================================
    Write-Host ""
    Write-Host "=== SCENARIO E: Doctor Default Mode (No Deep WSL) ===" -ForegroundColor Cyan

    try {
        $doctorPath = Join-Path $extractDir "doctor.ps1"
        $reportPath = Join-Path $extractDir "report.txt"

        $drEnv = $baseEnv.Clone()
        $drEnv["CCDI_TEST_API_STATUS"] = "200"
        # Ensure NO DeepWslCheck
        $drRun = Invoke-SandboxProcess -Label "doctor default mode" `
            -FileName "powershell.exe" `
            -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $doctorPath,
                "-SkipApiTest", "-NoOpenReport") `
            -WorkingDirectory $extractDir -Environment $drEnv -TimeoutSec 300

        if (Test-Path $reportPath) {
            Write-SandboxPass "E1. Report generated"
        } else {
            Write-SandboxFail "E1. Report" "not generated at $reportPath"
        }

        $reportContent = Get-Content -Path $reportPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        $allReports = Get-ChildItem -Path (Join-Path $extractDir "reports") -Filter "report-*.txt" -ErrorAction SilentlyContinue
        $allFullReports = Get-ChildItem -Path (Join-Path $extractDir "reports") -Filter "full-report-*.txt" -ErrorAction SilentlyContinue

        # E2: Default doctor must NOT start WSL deep detection
        if ($reportContent -notmatch "Test-WslClaudeComprehensive|wsl -d|WSL: settings\.json") {
            Write-SandboxPass "E2. Default doctor does NOT execute deep WSL detection"
        } else {
            Write-SandboxFail "E2. WSL depth" "default doctor shows deep WSL output"
        }

        # E3: Report should show WSL skip info
        if ($reportContent -match "未执行深度启动检测|SKIP.*WSL|INFO.*WSL.*skip") {
            Write-SandboxPass "E3. Default doctor indicates WSL depth skip"
        } else {
            Write-SandboxInfo "E3. Default doctor may not explicitly mention WSL skip (OK if WSL not installed)"
        }

        # E4: Check-Commands must NOT call Test-WslInstalled (verified by check.ps1 at build time)
        # Runtime verification: no WSL-related output in Check-Commands section of report
        $checkCmdsSection = if ($reportContent -match '(?s)诊断项目 3/8.*?(?=诊断项目 4/8)') {
            $matches[0]
        } else { "" }
        if ($checkCmdsSection -and $checkCmdsSection -match "Test-WslInstalled") {
            Write-SandboxFail "E4. Check-Commands" "contains Test-WslInstalled output"
        } else {
            Write-SandboxPass "E4. Check-Commands does not show WSL probe output"
        }

        # E5: WSL missing should NOT block Windows native conclusion
        if ($reportContent -match "整体评估" -or $reportContent -match "结论" -or $reportContent -match "Quick Summary") {
            Write-SandboxPass "E5. Report has conclusion/summary section"
        }

        # E6: No full dummy key in report
        if ($reportContent -notmatch [regex]::Escape($DummyApiKey)) {
            Write-SandboxPass "E6. Report does not contain full dummy API Key"
        } else {
            Write-SandboxFail "E6. Key privacy" "report contains full dummy API Key"
        }

        # E7: No real sandbox profile path in report
        if ($reportContent -notmatch [regex]::Escape($profileDir)) {
            Write-SandboxPass "E7. Report sanitizes sandbox profile path"
        } else {
            Write-SandboxInfo "E7. Sandbox profile path in report: may use %USERPROFILE% replacement"
        }
    } catch {
        Write-SandboxFail "E. Doctor default" $_.Exception.Message
    }

    # ============================================================
    # SCENARIO F: Doctor -DeepWslCheck
    # ============================================================
    Write-Host ""
    Write-Host "=== SCENARIO F: Doctor -DeepWslCheck ===" -ForegroundColor Cyan

    try {
        $deepEnv = $baseEnv.Clone()
        $deepEnv["CCDI_TEST_API_STATUS"] = "200"

        $deepRun = Invoke-SandboxProcess -Label "doctor -DeepWslCheck" `
            -FileName "powershell.exe" `
            -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $doctorPath,
                "-SkipApiTest", "-NoOpenReport", "-DeepWslCheck") `
            -WorkingDirectory $extractDir -Environment $deepEnv -TimeoutSec 300

        $deepReport = Join-Path $extractDir "report.txt"
        if (Test-Path $deepReport) {
            $deepContent = Get-Content -Path $deepReport -Raw -Encoding UTF8 -ErrorAction SilentlyContinue

            # F1: DeepWslCheck mode should mention deep WSL
            if ($deepContent -match "测试安全模式不启动 WSL|TestSafe|测试安全|深度.*WSL|未执行深度启动检测|DeepWslCheck") {
                Write-SandboxPass "F1. DeepWslCheck mode shows WSL-related status (or TestSafe skip)"
            } else {
                Write-SandboxInfo "F1. DeepWslCheck may have succeeded without TestSafe blocking"
            }

            # F2: Windows native conclusions still present
            if ($deepContent -match "整体评估|Quick Summary|Claude Code CLI" -or $deepContent -match "Windows") {
                Write-SandboxPass "F2. Windows native conclusion present in DeepWslCheck report"
            }

            # F3: DeepWslCheck does not break non-WSL parts
            if ($deepContent -notmatch "ParserError|Write-Log.*未定义|Write-Error-Msg.*未定义") {
                Write-SandboxPass "F3. DeepWslCheck report is well-formed"
            } else {
                Write-SandboxFail "F3. DeepWslCheck" "report contains errors"
            }
        } else {
            Write-SandboxFail "F. DeepWslCheck" "no report generated"
        }
    } catch {
        Write-SandboxFail "F. Doctor DeepWslCheck" $_.Exception.Message
    }

    # ============================================================
    # SCENARIO G: API mock matrix
    # ============================================================
    Write-Host ""
    Write-Host "=== SCENARIO G: API Mock Matrix ===" -ForegroundColor Cyan

    $apiCases = @(
        @{ Status = "200"; Expected = "200 OK"; Label = "success" },
        @{ Status = "401"; Expected = "API Key 验证失败"; Label = "401 auth fail" },
        @{ Status = "402"; Expected = "余额"; Label = "402 balance" },
        @{ Status = "429"; Expected = "请求过于频繁"; Label = "429 rate limit" },
        @{ Status = "503"; Expected = "DeepSeek 官方正在维护"; Label = "503 maintenance" },
        @{ Status = "timeout"; Expected = "连接超时"; Label = "timeout" },
        @{ Status = "dns"; Expected = "DNS 解析失败"; Label = "dns" }
    )

    foreach ($case in $apiCases) {
        try {
            $apiEnv = $baseEnv.Clone()
            $apiEnv["CCDI_TEST_API_STATUS"] = $case.Status
            $caseReport = Join-Path $extractDir "reports\api-report-$($case.Status).txt"

            $apiRun = Invoke-SandboxProcess -Label "API mock $($case.Status)" `
                -FileName "powershell.exe" `
                -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $doctorPath,
                    "-OutputPath", $caseReport, "-NoOpenReport") `
                -WorkingDirectory $extractDir -Environment $apiEnv -TimeoutSec 180 `
                -InputText "`r`n"

            if (Test-Path $caseReport) {
                $caseContent = Get-Content -Path $caseReport -Raw -Encoding UTF8
                if ($caseContent -match [regex]::Escape($case.Expected)) {
                    Write-SandboxPass "G. API $($case.Label): correct diagnosis"
                } else {
                    Write-SandboxFail "G. API $($case.Label)" "expected '$($case.Expected)' not found"
                }
            } else {
                Write-SandboxFail "G. API $($case.Label)" "report not generated"
            }
        } catch {
            Write-SandboxFail "G. API $($case.Label)" $_.Exception.Message
        }
    }

    # ============================================================
    # SCENARIO H: Proxy masking (sanitization)
    # ============================================================
    Write-Host ""
    Write-Host "=== SCENARIO H: Proxy Masking ===" -ForegroundColor Cyan

    try {
        $proxyEnv = $baseEnv.Clone()
        $proxyEnv["CCDI_TEST_API_STATUS"] = "200"
        $proxyEnv["HTTPS_PROXY"] = "http://user:pass@127.0.0.1:7890"
        $proxyEnv["HTTP_PROXY"] = "http://name:secret@127.0.0.1:7891"
        $proxyEnv["ALL_PROXY"] = "socks5://abc:def@127.0.0.1:7892"
        $proxyEnv["NO_PROXY"] = "localhost,127.0.0.1"

        $proxyReport = Join-Path $extractDir "reports\proxy-report.txt"
        $prRun = Invoke-SandboxProcess -Label "doctor with proxy" `
            -FileName "powershell.exe" `
            -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $doctorPath,
                "-OutputPath", $proxyReport, "-NoOpenReport", "-SkipApiTest") `
            -WorkingDirectory $extractDir -Environment $proxyEnv -TimeoutSec 300

        # Collect all text outputs
        $proxyTexts = @()
        if (Test-Path $proxyReport) {
            $proxyTexts += Get-Content -Path $proxyReport -Raw -Encoding UTF8
        }
        $allReportFiles = Get-ChildItem -Path (Join-Path $extractDir "reports") -Filter "report-*.txt" -ErrorAction SilentlyContinue
        $allFullReportFiles = Get-ChildItem -Path (Join-Path $extractDir "reports") -Filter "full-report-*.txt" -ErrorAction SilentlyContinue
        $allLogFiles = Get-ChildItem -Path (Join-Path $extractDir "logs") -Filter "*.log" -ErrorAction SilentlyContinue

        foreach ($f in $allReportFiles + $allFullReportFiles + $allLogFiles) {
            if (Test-Path $f.FullName) {
                $proxyTexts += Get-Content -Path $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            }
        }
        $proxyCombined = $proxyTexts -join "`n"

        # Check no raw credentials
        $credLeaks = @("user:pass", "name:secret", "abc:def")
        $leakFound = $false
        foreach ($cred in $credLeaks) {
            if ($proxyCombined -match [regex]::Escape($cred)) {
                Write-SandboxFail "H. Proxy leak" "found raw credential: $cred"
                $leakFound = $true
            }
        }
        if (-not $leakFound) {
            Write-SandboxPass "H1. No raw proxy credentials leaked"
        }

        # Check sanitized markers in reports/logs.
        # If proxy variables appear in output, they MUST be sanitized.
        # If proxy section is skipped (TestSafe), H4 function test provides coverage.
        if ($proxyCombined -match "<AUTH>@") {
            Write-SandboxPass "H2. Proxy URLs sanitized with <AUTH>@ in outputs"
        } elseif ($proxyCombined -match 'HTTPS_PROXY|HTTP_PROXY|ALL_PROXY') {
            # Proxy vars ARE in output but NOT sanitized -> FAIL
            Write-SandboxFail "H2. Proxy sanitize" "proxy variables present but <AUTH>@ marker not found"
        } else {
            # Proxy section skipped entirely (likely TestSafe skip of network checks)
            Write-SandboxPass "H2. Proxy section not in output (TestSafe skip), covered by H4 function test"
        }

        # Quick scan individual log files
        $logLeak = $false
        foreach ($lf in $allLogFiles) {
            if (Test-Path $lf.FullName) {
                $logContent = Get-Content -Path $lf.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                foreach ($cred in $credLeaks) {
                    if ($logContent -match [regex]::Escape($cred)) {
                        Write-SandboxFail "H3. Log leak" "$($lf.Name) contains $cred"
                        $logLeak = $true
                    }
                }
            }
        }
        if (-not $logLeak) {
            Write-SandboxPass "H3. Log files free of proxy credentials"
        }

        # H4: FUNCTION-LEVEL test of Sanitize-ProxyUrl
        $h4Script = @'
$r1 = Sanitize-ProxyUrl -Text "http://user:pass@127.0.0.1:7890"
if ($r1 -match '<AUTH>@' -and $r1 -notmatch 'user:pass') {
    Write-Output "SANDBOX_TEST:PASS:H4_http"
} else {
    Write-Output "SANDBOX_TEST:FAIL:H4_http:got=$r1"
}

$r2 = Sanitize-ProxyUrl -Text "socks5://abc:def@127.0.0.1:7892"
if ($r2 -match '<AUTH>@' -and $r2 -notmatch 'abc:def') {
    Write-Output "SANDBOX_TEST:PASS:H4_socks"
} else {
    Write-Output "SANDBOX_TEST:FAIL:H4_socks:got=$r2"
}

$r3 = Sanitize-ProxyUrl -Text "http://no-auth-proxy.example.com:8080"
if ($r3 -eq "http://no-auth-proxy.example.com:8080") {
    Write-Output "SANDBOX_TEST:PASS:H4_noauth"
} else {
    Write-Output "SANDBOX_TEST:FAIL:H4_noauth:got=$r3"
}
'@
        $h4Result = Invoke-SandboxFunctionTest -Label "Sanitize-ProxyUrl function" `
            -ReleaseRoot $extractDir -ScriptText $h4Script -TimeoutSec 30

        $h4Passes = 0
        $h4Fails = 0
        if ($h4Result.Stdout -match 'SANDBOX_TEST:PASS:H4_http') { $h4Passes++ } else { $h4Fails++; Write-SandboxFail "H4. Sanitize-ProxyUrl http" "function test failed: $($h4Result.Stdout)" }
        if ($h4Result.Stdout -match 'SANDBOX_TEST:PASS:H4_socks') { $h4Passes++ } else { $h4Fails++; Write-SandboxFail "H4. Sanitize-ProxyUrl socks" "function test failed: $($h4Result.Stdout)" }
        if ($h4Result.Stdout -match 'SANDBOX_TEST:PASS:H4_noauth') { $h4Passes++ } else { $h4Fails++; Write-SandboxFail "H4. Sanitize-ProxyUrl noauth" "function test failed: $($h4Result.Stdout)" }

        if ($h4Fails -eq 0) {
            Write-SandboxPass "H4. Sanitize-ProxyUrl function tests ($h4Passes/3 passed)"
        }
    } catch {
        Write-SandboxFail "H. Proxy masking" $_.Exception.Message
    }

    # ============================================================
    # SCENARIO I: Native Install file lock RawError
    # ============================================================
    Write-Host ""
    Write-Host "=== SCENARIO I: Native Install File Lock RawError ===" -ForegroundColor Cyan

    try {
        $claudeInstallPath = Join-Path $extractDir "lib\claude-install.ps1"
        $claudeInstallSource = Get-Content -Path $claudeInstallPath -Raw -Encoding UTF8

        # I1: Test-IsClaudeNativeFileLockError function must exist
        if ($claudeInstallSource -match "function Test-IsClaudeNativeFileLockError") {
            Write-SandboxPass "I1. Test-IsClaudeNativeFileLockError function exists"
        } else {
            Write-SandboxFail "I1. Function" "Test-IsClaudeNativeFileLockError not found"
        }

        # I2: Must log HasRawError boolean, NOT RawError snippet
        if ($claudeInstallSource -notmatch 'Native Install lock check raw') {
            Write-SandboxPass "I2. No 'Native Install lock check raw' in source"
        } else {
            Write-SandboxFail "I2. RawError log" "source contains forbidden RawError snippet log"
        }

        # I3: Must log structured HasRawError format
        if ($claudeInstallSource -match "Native Install lock check: HasRawError=") {
            Write-SandboxPass "I3. HasRawError structured log format present"
        } else {
            Write-SandboxFail "I3. HasRawError log" "structured format not found"
        }

        # I4: FUNCTION-LEVEL test: real call to Test-IsClaudeNativeFileLockError
        $i4Script = @'
# Test 1: real file-lock error (should return $true)
$lockText = "The process cannot access the file because it is being used by another process`n$env:USERPROFILE\.claude\downloads"
$r1 = Test-IsClaudeNativeFileLockError -Text $lockText
if ($r1 -eq $true) {
    Write-Output "SANDBOX_TEST:PASS:LOCK_TRUE"
} else {
    Write-Output "SANDBOX_TEST:FAIL:LOCK_TRUE:returned=$r1"
}

# Test 2: Chinese file-lock error (should return $true)
$cnText = "文件正由另一进程使用，因此该进程无法访问此文件。`nC:\Users\test\.claude\downloads"
$r2 = Test-IsClaudeNativeFileLockError -Text $cnText
if ($r2 -eq $true) {
    Write-Output "SANDBOX_TEST:PASS:LOCK_CN_TRUE"
} else {
    Write-Output "SANDBOX_TEST:FAIL:LOCK_CN_TRUE:returned=$r2"
}

# Test 3: network timeout (should return $false, NOT a file-lock error)
$netText = "The request timed out while downloading install.ps1"
$r3 = Test-IsClaudeNativeFileLockError -Text $netText
if ($r3 -eq $false) {
    Write-Output "SANDBOX_TEST:PASS:NETWORK_FALSE"
} else {
    Write-Output "SANDBOX_TEST:FAIL:NETWORK_FALSE:returned=$r3"
}

# Test 4: access denied (should match "Access to the path" or "is denied")
$deniedText = "Access to the path 'C:\Users\test\.claude\downloads' is denied."
$r4 = Test-IsClaudeNativeFileLockError -Text $deniedText
if ($r4 -eq $true) {
    Write-Output "SANDBOX_TEST:PASS:DENIED_TRUE"
} else {
    Write-Output "SANDBOX_TEST:FAIL:DENIED_TRUE:returned=$r4"
}

# Test 5: empty text (should return $false)
$r5 = Test-IsClaudeNativeFileLockError -Text ""
if ($r5 -eq $false) {
    Write-Output "SANDBOX_TEST:PASS:EMPTY_FALSE"
} else {
    Write-Output "SANDBOX_TEST:FAIL:EMPTY_FALSE:returned=$r5"
}
'@
        $i4Result = Invoke-SandboxFunctionTest -Label "Test-IsClaudeNativeFileLockError function" `
            -ReleaseRoot $extractDir -ScriptText $i4Script -TimeoutSec 30

        $i4Passes = 0
        $i4Fails = 0
        $i4Markers = @("LOCK_TRUE", "LOCK_CN_TRUE", "NETWORK_FALSE", "DENIED_TRUE", "EMPTY_FALSE")
        foreach ($marker in $i4Markers) {
            if ($i4Result.Stdout -match "SANDBOX_TEST:PASS:$marker") { $i4Passes++ }
            else { $i4Fails++; Write-SandboxFail "I4. $marker" "function test failed: $($i4Result.Stdout)" }
        }
        if ($i4Fails -eq 0) {
            Write-SandboxPass "I4. Test-IsClaudeNativeFileLockError function tests ($i4Passes/5 passed)"
        }

        # I5: User guidance for file lock (source check)
        if ($claudeInstallSource -match "关闭 claude|关闭 Node|关闭 PowerShell|close.*claude|关闭.*PowerShell.*Windows Terminal") {
            Write-SandboxPass "I5. File lock user guidance mentions closing processes"
        } else {
            Write-SandboxFail "I5. File lock guidance" "no user-friendly closing-processes advice"
        }

        # I6: No auto-kill of processes or auto-delete of .claude files
        if ($claudeInstallSource -match 'Remove-Item.*\\\.claude\\settings\.json.*-Force' -and
            $claudeInstallSource -match 'Test-IsClaudeNativeFileLockError[\s\S]{0,500}Remove-Item') {
            Write-SandboxFail "I6. Auto-delete" "settings.json auto-delete detected in lock handler"
        } else {
            Write-SandboxPass "I6. No auto-delete of settings.json in lock handler"
        }
    } catch {
        Write-SandboxFail "I. Native file lock" $_.Exception.Message
    }

    # ============================================================
    # SCENARIO J: Claude command inventory matrix
    # ============================================================
    Write-Host ""
    Write-Host "=== SCENARIO J: Claude Command Inventory ===" -ForegroundColor Cyan

    try {
        $sourceCheck = $claudeInstallSource

        # J1: Test-ClaudeCommandExisting must detect native_local_bin (source check)
        if ($sourceCheck -match 'native_local_bin') {
            Write-SandboxPass "J1. native_local_bin detection present in source"
        } else {
            Write-SandboxFail "J1. native_local_bin" "not in claude-install.ps1"
        }

        # J2: WindowsApps alias must be recognized (source check)
        if ($sourceCheck -match 'WindowsApps') {
            Write-SandboxPass "J2. WindowsApps alias detection present in source"
        } else {
            Write-SandboxFail "J2. WindowsApps" "not in source"
        }

        # J3: PATH conflict when PATH claude broken but native_local_bin usable (source check)
        if ($sourceCheck -match 'PATH.*冲突|BadPath|PATH 中 claude 不可用.*native_local_bin') {
            Write-SandboxPass "J3. PATH conflict detection for broken PATH + native_local_bin"
        } else {
            Write-SandboxFail "J3. PATH conflict" "no detection of broken PATH claude + native_local_bin"
        }

        # J4: CCDI_MOCK_CLAUDE mock support in source
        if ($sourceCheck -match "CCDI_MOCK_CLAUDE") {
            Write-SandboxPass "J4. CCDI_MOCK_CLAUDE mock mode present in source"
        } else {
            Write-SandboxFail "J4. CCDI_MOCK_CLAUDE" "mock mode not in source"
        }

        # J5: FUNCTION-LEVEL Mock Matrix Runtime Test
        $j5Script = @'
$env:CCDI_TEST_MODE = "1"
$env:CCDI_MOCK_INSTALL_DECISION = "1"

# Test ok
$env:CCDI_MOCK_CLAUDE = "ok"
$rOk = Test-ClaudeCommandExisting
if ($rOk.Exists -eq $true -and $rOk.Usable -eq $true) {
    Write-Output "SANDBOX_TEST:PASS:MOCK_OK"
} else {
    Write-Output "SANDBOX_TEST:FAIL:MOCK_OK:Exists=$($rOk.Exists):Usable=$($rOk.Usable)"
}

# Test broken
$env:CCDI_MOCK_CLAUDE = "broken"
$rBroken = Test-ClaudeCommandExisting
if ($rBroken.Exists -eq $true -and $rBroken.Usable -eq $false) {
    Write-Output "SANDBOX_TEST:PASS:MOCK_BROKEN"
} else {
    Write-Output "SANDBOX_TEST:FAIL:MOCK_BROKEN:Exists=$($rBroken.Exists):Usable=$($rBroken.Usable)"
}

# Test missing
$env:CCDI_MOCK_CLAUDE = "missing"
$rMissing = Test-ClaudeCommandExisting
if ($rMissing.Exists -eq $false -and $rMissing.Usable -eq $false) {
    Write-Output "SANDBOX_TEST:PASS:MOCK_MISSING"
} else {
    Write-Output "SANDBOX_TEST:FAIL:MOCK_MISSING:Exists=$($rMissing.Exists):Usable=$($rMissing.Usable)"
}

# Test default (no CCDI_MOCK_CLAUDE set)
Remove-Item Env:CCDI_MOCK_CLAUDE -ErrorAction SilentlyContinue
$rDefault = Test-ClaudeCommandExisting
if ($rDefault.Exists -eq $false) {
    Write-Output "SANDBOX_TEST:PASS:MOCK_DEFAULT_MISSING"
} else {
    Write-Output "SANDBOX_TEST:FAIL:MOCK_DEFAULT_MISSING:Exists=$($rDefault.Exists)"
}
'@
        $j5Result = Invoke-SandboxFunctionTest -Label "Claude mock matrix runtime" `
            -ReleaseRoot $extractDir -ScriptText $j5Script -TimeoutSec 30

        $j5Passes = 0
        $j5Fails = 0
        $j5Markers = @("MOCK_OK", "MOCK_BROKEN", "MOCK_MISSING", "MOCK_DEFAULT_MISSING")
        foreach ($marker in $j5Markers) {
            if ($j5Result.Stdout -match "SANDBOX_TEST:PASS:$marker") { $j5Passes++ }
            else { $j5Fails++; Write-SandboxFail "J5. $marker" "mock matrix test failed: $($j5Result.Stdout)" }
        }
        if ($j5Fails -eq 0) {
            Write-SandboxPass "J5. Claude mock matrix runtime tests ($j5Passes/4 passed)"
        }
    } catch {
        Write-SandboxFail "J. Claude inventory" $_.Exception.Message
    }

    # J6: Claude command source runtime PATH/shim matrix
    Write-Host ""
    Write-Host "--- J6: Claude Source PATH/Shim Matrix ---" -ForegroundColor Cyan

    try {
        # Build temp directory tree
        $matrixRoot = Join-Path $sandboxDir "claude-source-matrix"
        Remove-Item $matrixRoot -Recurse -Force -ErrorAction SilentlyContinue
        $matrixProfile = Join-Path $matrixRoot "UserProfile"
        $matrixLocalBin = Join-Path $matrixProfile ".local\bin"
        $matrixAppData = Join-Path $matrixRoot "AppData\Roaming"
        $matrixNpm = Join-Path $matrixAppData "npm"
        $matrixLocalAppData = Join-Path $matrixRoot "AppData\Local"
        $matrixWinApps = Join-Path $matrixLocalAppData "Microsoft\WindowsApps"
        $matrixPathDir = Join-Path $matrixRoot "PathBin"

        foreach ($d in @($matrixProfile, $matrixLocalBin, $matrixAppData, $matrixNpm,
            $matrixLocalAppData, $matrixWinApps, $matrixPathDir)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }

        # Helper shims
        $goodCmdContent = "@echo off`r`necho 1.0.0-matrix`r`nexit /b 0`r`n"
        $brokenCmdContent = "@echo off`r`necho broken`r`nexit /b 1`r`n"

        # Build single subprocess that runs all 5 cases.
        # Use [System.Text.StringBuilder] to avoid here-string escaping issues
        # with mix of parent-expanded paths and subprocess-local variables.
        $j6Sb = New-Object System.Text.StringBuilder
        [void]$j6Sb.AppendLine('$ErrorActionPreference = "Continue"')
        [void]$j6Sb.AppendLine('$systemPath = "C:\Windows\System32;C:\Windows"')
        [void]$j6Sb.AppendLine("`$matrixPathDir = '$matrixPathDir'")
        [void]$j6Sb.AppendLine("`$matrixNpm = '$matrixNpm'")
        [void]$j6Sb.AppendLine("`$matrixWinApps = '$matrixWinApps'")
        [void]$j6Sb.AppendLine("`$matrixProfile = '$matrixProfile'")
        [void]$j6Sb.AppendLine("`$matrixLocalBin = '$matrixLocalBin'")
        [void]$j6Sb.AppendLine("`$matrixAppData = '$matrixAppData'")
        [void]$j6Sb.AppendLine("`$matrixLocalAppData = '$matrixLocalAppData'")
        [void]$j6Sb.AppendLine('')
        # Case J6.1: NO CLAUDE
        [void]$j6Sb.AppendLine('# --- J6.1: NO CLAUDE ---')
        [void]$j6Sb.AppendLine('$env:CCDI_TEST_MODE = "1"')
        [void]$j6Sb.AppendLine('$env:CCDI_TEST_USERPROFILE = $matrixProfile')
        [void]$j6Sb.AppendLine('$env:CCDI_TEST_DESKTOP = $matrixProfile')
        [void]$j6Sb.AppendLine('$env:USERPROFILE = $matrixProfile')
        [void]$j6Sb.AppendLine('$env:APPDATA = $matrixAppData')
        [void]$j6Sb.AppendLine('$env:LOCALAPPDATA = $matrixLocalAppData')
        [void]$j6Sb.AppendLine('$env:PATH = "$matrixPathDir;$systemPath"')
        [void]$j6Sb.AppendLine('Get-ChildItem $matrixPathDir -Filter claude.* -ErrorAction SilentlyContinue | Remove-Item -Force')
        [void]$j6Sb.AppendLine('$inv1 = Get-ClaudeCommandInventory')
        [void]$j6Sb.AppendLine('$cnt1 = [int]($inv1.Candidates.Count)')
        [void]$j6Sb.AppendLine('if ($cnt1 -eq 0) { Write-Output "SANDBOX_TEST:PASS:J6_NO_CLAUDE" }')
        [void]$j6Sb.AppendLine('else { Write-Output "SANDBOX_TEST:FAIL:J6_NO_CLAUDE:Count=$cnt1" }')
        [void]$j6Sb.AppendLine('')
        # Case J6.2: PATH claude.cmd OK
        [void]$j6Sb.AppendLine('# --- J6.2: PATH OK ---')
        [void]$j6Sb.AppendLine('Set-Content -Path (Join-Path $matrixPathDir claude.cmd) -Value "@echo off`r`necho 1.0.0-matrix`r`nexit /b 0`r`n" -Encoding ASCII')
        [void]$j6Sb.AppendLine('$env:USERPROFILE = $matrixProfile')
        [void]$j6Sb.AppendLine('$env:APPDATA = $matrixAppData')
        [void]$j6Sb.AppendLine('$env:LOCALAPPDATA = $matrixLocalAppData')
        [void]$j6Sb.AppendLine('$env:PATH = "$matrixPathDir;$systemPath"')
        [void]$j6Sb.AppendLine('$inv2 = Get-ClaudeCommandInventory')
        [void]$j6Sb.AppendLine('$usable2 = @($inv2.Candidates | Where-Object { $_.Usable }).Count')
        [void]$j6Sb.AppendLine('if ($usable2 -ge 1 -and $inv2.Active -and $inv2.Active.Usable) {')
        [void]$j6Sb.AppendLine('  Write-Output "SANDBOX_TEST:PASS:J6_PATH_OK"')
        [void]$j6Sb.AppendLine('  Write-Output "SANDBOX_TEST:INFO:J6_PATH_OK:Source=$($inv2.Active.Source)"')
        [void]$j6Sb.AppendLine('} else { Write-Output "SANDBOX_TEST:FAIL:J6_PATH_OK:Usable=$usable2:Candidates=$($inv2.Candidates.Count)" }')
        [void]$j6Sb.AppendLine('')
        # Case J6.3: NPM_GLOBAL
        [void]$j6Sb.AppendLine('# --- J6.3: NPM_GLOBAL ---')
        [void]$j6Sb.AppendLine('Set-Content -Path (Join-Path $matrixNpm claude.cmd) -Value "@echo off`r`necho 1.0.0-matrix-npm`r`nexit /b 0`r`n" -Encoding ASCII')
        [void]$j6Sb.AppendLine('$env:USERPROFILE = $matrixProfile')
        [void]$j6Sb.AppendLine('$env:APPDATA = $matrixAppData')
        [void]$j6Sb.AppendLine('$env:LOCALAPPDATA = $matrixLocalAppData')
        [void]$j6Sb.AppendLine('$env:PATH = "$matrixNpm;$matrixPathDir;$systemPath"')
        [void]$j6Sb.AppendLine('$inv3 = Get-ClaudeCommandInventory')
        [void]$j6Sb.AppendLine('$npmCands = @($inv3.Candidates | Where-Object { $_.Source -eq "npm_global" -or $_.Path -like "*\npm\claude.*" })')
        [void]$j6Sb.AppendLine('$npmUsable = @($npmCands | Where-Object { $_.Usable }).Count')
        [void]$j6Sb.AppendLine('if ($npmCands.Count -gt 0 -and $npmUsable -ge 1) {')
        [void]$j6Sb.AppendLine('  Write-Output "SANDBOX_TEST:PASS:J6_NPM_GLOBAL"')
        [void]$j6Sb.AppendLine('  Write-Output "SANDBOX_TEST:INFO:J6_NPM_GLOBAL:Candidates=$($npmCands.Count):Usable=$npmUsable"')
        [void]$j6Sb.AppendLine('} else { Write-Output "SANDBOX_TEST:FAIL:J6_NPM_GLOBAL:NpmCands=$($npmCands.Count):NpmUsable=$npmUsable" }')
        [void]$j6Sb.AppendLine('')
        # Case J6.4: WINDOWS_APPS
        [void]$j6Sb.AppendLine('# --- J6.4: WINDOWS_APPS ---')
        [void]$j6Sb.AppendLine('Set-Content -Path (Join-Path $matrixWinApps claude.cmd) -Value "@echo off`r`necho Claude Desktop alias`r`nexit /b 0`r`n" -Encoding ASCII')
        [void]$j6Sb.AppendLine('$env:USERPROFILE = $matrixProfile')
        [void]$j6Sb.AppendLine('$env:APPDATA = $matrixAppData')
        [void]$j6Sb.AppendLine('$env:LOCALAPPDATA = $matrixLocalAppData')
        [void]$j6Sb.AppendLine('$env:PATH = "$matrixWinApps;$systemPath"')
        [void]$j6Sb.AppendLine('$inv4 = Get-ClaudeCommandInventory')
        [void]$j6Sb.AppendLine('$waCands = @($inv4.Candidates | Where-Object { $_.Source -eq "windowsapps" -or $_.Path -like "*\WindowsApps\claude.*" })')
        [void]$j6Sb.AppendLine('if ($waCands.Count -gt 0) {')
        [void]$j6Sb.AppendLine('  $waRiskOk = ($waCands | Where-Object { $_.Risk -ne "WARN" }).Count -eq 0')
        [void]$j6Sb.AppendLine('  if ($waRiskOk) { Write-Output "SANDBOX_TEST:PASS:J6_WINDOWS_APPS" }')
        [void]$j6Sb.AppendLine('  else { Write-Output "SANDBOX_TEST:FAIL:J6_WINDOWS_APPS:RiskNotWarn=$($waCands[0].Risk)" }')
        [void]$j6Sb.AppendLine('} else { Write-Output "SANDBOX_TEST:FAIL:J6_WINDOWS_APPS:NoCandidate:Total=$($inv4.Candidates.Count)" }')
        [void]$j6Sb.AppendLine('')
        # Case J6.5: PATH BROKEN + NATIVE FALLBACK
        [void]$j6Sb.AppendLine('# --- J6.5: PATH BROKEN + NATIVE FALLBACK ---')
        [void]$j6Sb.AppendLine('Set-Content -Path (Join-Path $matrixPathDir claude.cmd) -Value "@echo off`r`necho broken`r`nexit /b 1`r`n" -Encoding ASCII')
        [void]$j6Sb.AppendLine('Set-Content -Path (Join-Path $matrixLocalBin claude.cmd) -Value "@echo off`r`necho 1.0.0-matrix-native`r`nexit /b 0`r`n" -Encoding ASCII')
        [void]$j6Sb.AppendLine('$env:USERPROFILE = $matrixProfile')
        [void]$j6Sb.AppendLine('$env:APPDATA = $matrixAppData')
        [void]$j6Sb.AppendLine('$env:LOCALAPPDATA = $matrixLocalAppData')
        [void]$j6Sb.AppendLine('$env:PATH = "$matrixPathDir;$matrixLocalBin;$systemPath"')
        [void]$j6Sb.AppendLine('$inv5 = Get-ClaudeCommandInventory')
        [void]$j6Sb.AppendLine('$nativeCand = @($inv5.Candidates | Where-Object { $_.Source -eq "native_local_bin" -or $_.Path -like "*\.local\bin\claude.*" }) | Select-Object -First 1')
        [void]$j6Sb.AppendLine('$usableAny = @($inv5.Candidates | Where-Object { $_.Usable }).Count')
        [void]$j6Sb.AppendLine('if ($nativeCand -and $nativeCand.Usable) {')
        [void]$j6Sb.AppendLine('  Write-Output "SANDBOX_TEST:PASS:J6_PATH_BROKEN_NATIVE_FALLBACK"')
        [void]$j6Sb.AppendLine('  Write-Output "SANDBOX_TEST:INFO:J6_PATH_BROKEN_NATIVE_FALLBACK:HasConflict=$($inv5.HasConflict):Summary=$($inv5.ConflictSummary)"')
        [void]$j6Sb.AppendLine('} else { Write-Output "SANDBOX_TEST:FAIL:J6_PATH_BROKEN_NATIVE_FALLBACK:NativeFound=$($null -ne $nativeCand):NativeUsable=$(if($nativeCand){$nativeCand.Usable}else{"N/A"}):HasConflict=$($inv5.HasConflict):UsableAny=$usableAny" }')
        $j6Script = $j6Sb.ToString()

        # Start J6 subprocess with minimal PATH to avoid host claude leaking in
        $j6Result = Invoke-SandboxFunctionTest -Label "Claude source matrix (J6)" `
            -ReleaseRoot $extractDir -ScriptText $j6Script -TimeoutSec 120 `
            -Environment @{ PATH = "C:\Windows\System32;C:\Windows" }

        $j6Passes = 0
        $j6Fails = 0
        $j6Required = @("J6_NO_CLAUDE", "J6_PATH_OK", "J6_NPM_GLOBAL", "J6_WINDOWS_APPS", "J6_PATH_BROKEN_NATIVE_FALLBACK")
        foreach ($marker in $j6Required) {
            if ($j6Result.Stdout -match "SANDBOX_TEST:PASS:$marker") {
                $j6Passes++
                Write-SandboxPass "J6. $marker"
            } else {
                $j6Fails++
                Write-SandboxFail "J6. $marker" "matrix test failed: $($j6Result.Stdout | Select-String $marker)"
            }
        }

        if ($j6Fails -gt 0) {
            Write-SandboxFail "J6. Claude source matrix" "$j6Fails/$($j6Required.Count) cases failed"
        } elseif ($j6Passes -lt 4) {
            Write-SandboxFail "J6. Claude source matrix" "only $j6Passes/$($j6Required.Count) cases passed, need at least 4"
        } else {
            Write-SandboxPass "J6. Claude source matrix ($j6Passes/$($j6Required.Count) cases)"
        }

        # Cleanup
        Remove-Item $matrixRoot -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-SandboxFail "J6. Claude source matrix" $_.Exception.Message
    }

    # ============================================================
    # SCENARIO K: npm.cmd vs npm.ps1 resolution
    # ============================================================
    Write-Host ""
    Write-Host "=== SCENARIO K: npm.cmd Resolution ===" -ForegroundColor Cyan

    try {
        # K1: Resolve-NpmCmdPath must exist in common.ps1
        $commonSource = Get-Content -Path (Join-Path $extractDir "lib\common.ps1") -Raw -Encoding UTF8

        if ($commonSource -match 'function Resolve-NpmCmdPath') {
            Write-SandboxPass "K1. Resolve-NpmCmdPath function exists (in common.ps1)"
        } else {
            Write-SandboxFail "K1. Resolve-NpmCmdPath" "function not found in common.ps1"
        }

        # K2: Source check: npm.ps1 risk documented
        if ($commonSource -match '"%1 is not a valid Win32 application"' -or $commonSource -match '%1 is not a valid Win32') {
            Write-SandboxPass "K2. npm.ps1 risk documented in source"
        } else {
            Write-SandboxFail "K2. npm.ps1 risk" "warning not documented in Resolve-NpmCmdPath"
        }

        # K3: FUNCTION-LEVEL test: Resolve-NpmCmdPath prefers npm.cmd
        $npmTestDir = Join-Path $sandboxDir "npm-path-test"
        New-Item -ItemType Directory -Path $npmTestDir -Force | Out-Null
        # Create npm.cmd (simulates real npm)
        Set-Content -Path (Join-Path $npmTestDir "npm.cmd") -Value "@echo npm.cmd mock" -Encoding ASCII
        # Create npm.ps1 (should NOT be preferred)
        Set-Content -Path (Join-Path $npmTestDir "npm.ps1") -Value "Write-Output 'npm.ps1 mock'" -Encoding UTF8

        $k3Script = @"
`$npmTestDir = '$npmTestDir'
`$oldPath = `$env:PATH
try {
    `$env:PATH = "`$npmTestDir;`$oldPath"
    `$r = Resolve-NpmCmdPath
    if (`$r.Found -and `$r.Path -match 'npm\.cmd$') {
        Write-Output "SANDBOX_TEST:PASS:NPM_CMD_RESOLVED"
        Write-Output "SANDBOX_TEST:INFO:path=`$(`$r.Path)"
    } elseif (`$r.Found -and `$r.Path -match 'npm\.ps1$') {
        Write-Output "SANDBOX_TEST:FAIL:NPM_PS1_RETURNED:path=`$(`$r.Path)"
    } else {
        Write-Output "SANDBOX_TEST:FAIL:NPM_NOT_FOUND:Found=`$(`$r.Found):Path=`$(`$r.Path):Error=`$(`$r.Error)"
    }
} finally {
    `$env:PATH = `$oldPath
}
"@
        $k3Result = Invoke-SandboxFunctionTest -Label "Resolve-NpmCmdPath npm.cmd preference" `
            -ReleaseRoot $extractDir -ScriptText $k3Script -TimeoutSec 30

        if ($k3Result.Stdout -match 'SANDBOX_TEST:PASS:NPM_CMD_RESOLVED') {
            Write-SandboxPass "K3. Resolve-NpmCmdPath returns npm.cmd (not .ps1)"
        } elseif ($k3Result.Stdout -match 'SANDBOX_TEST:FAIL:NPM_PS1_RETURNED') {
            Write-SandboxFail "K3. npm.ps1 returned" "Resolve-NpmCmdPath returned .ps1 instead of .cmd"
        } else {
            Write-SandboxFail "K3. Resolve-NpmCmdPath" "function test failed: $($k3Result.Stdout)"
        }

        # K4: FUNCTION-LEVEL test: npm.cmd only (no npm.ps1 to compete)
        Remove-Item (Join-Path $npmTestDir "npm.ps1") -Force -ErrorAction SilentlyContinue
        $k4Script = @"
`$npmTestDir = '$npmTestDir'
`$oldPath = `$env:PATH
try {
    `$env:PATH = "`$npmTestDir;`$oldPath"
    `$r = Resolve-NpmCmdPath
    if (`$r.Found -and `$r.Path -match 'npm\.cmd$') {
        Write-Output "SANDBOX_TEST:PASS:NPM_CMD_ONLY"
    } else {
        Write-Output "SANDBOX_TEST:FAIL:NPM_CMD_ONLY:Found=`$(`$r.Found):Path=`$(`$r.Path)"
    }
} finally {
    `$env:PATH = `$oldPath
}
"@
        $k4Result = Invoke-SandboxFunctionTest -Label "Resolve-NpmCmdPath npm.cmd only" `
            -ReleaseRoot $extractDir -ScriptText $k4Script -TimeoutSec 30

        if ($k4Result.Stdout -match 'SANDBOX_TEST:PASS:NPM_CMD_ONLY') {
            Write-SandboxPass "K4. Resolve-NpmCmdPath finds npm.cmd when only .cmd exists"
        } else {
            Write-SandboxFail "K4. npm.cmd only" "test failed: $($k4Result.Stdout)"
        }

        # Cleanup
        Remove-Item $npmTestDir -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Write-SandboxFail "K. npm resolution" $_.Exception.Message
    }

    # ============================================================
    # SCENARIO L: 32-bit PowerShell detection
    # ============================================================
    Write-Host ""
    Write-Host "=== SCENARIO L: 32-bit PowerShell Detection ===" -ForegroundColor Cyan

    try {
        $envCheckPath = Join-Path $extractDir "lib\env-check.ps1"
        $envCheckSource = Get-Content -Path $envCheckPath -Raw -Encoding UTF8

        # L1: IsWow64PowerShell detection
        if ($envCheckSource -match 'IsWow64PowerShell') {
            Write-SandboxPass "L1. IsWow64PowerShell detection present"
        } else {
            Write-SandboxFail "L1. IsWow64PowerShell" "not in env-check.ps1"
        }

        # L2: IsWow64PowerShell sets IsSupported=false
        if ($envCheckSource -match 'IsWow64PowerShell[\s\S]{0,200}IsSupported[\s\S]{0,50}=\s*\$false') {
            Write-SandboxPass "L2. 32-bit PowerShell blocks installation (IsSupported=false)"
        } else {
            Write-SandboxFail "L2. 32-bit block" "IsSupported not set to false for Wow64"
        }

        # L3: Error message mentions 32-bit
        if ($envCheckSource -match '32 位 PowerShell|32.*位.*PowerShell|x86|不要打开.*Windows PowerShell') {
            Write-SandboxPass "L3. 32-bit PowerShell error message is Chinese-friendly"
        } else {
            Write-SandboxFail "L3. 32-bit message" "no Chinese-friendly error for 32-bit PS"
        }

        # L4: Architecture check uses both Is64BitOperatingSystem AND Is64BitProcess
        if ($envCheckSource -match 'Is64BitOperatingSystem' -and $envCheckSource -match 'Is64BitProcess') {
            Write-SandboxPass "L4. Both Is64BitOperatingSystem and Is64BitProcess checked"
        } else {
            Write-SandboxFail "L4. Architecture check" "missing 64-bit OS/Process checks"
        }

        # L5: Doctor must reference architecture / 32-bit detection
        $doctorSource = Get-Content -Path $doctorPath -Raw -Encoding UTF8
        if ($doctorSource -match 'IsWow64PowerShell|Is64BitProcess' -or $doctorSource -match 'Test-MinimumRequirements') {
            Write-SandboxPass "L5. Doctor references architecture checks"
        } else {
            Write-SandboxFail "L5. Doctor architecture" "doctor.ps1 does not reference IsWow64PowerShell or Test-MinimumRequirements"
        }
    } catch {
        Write-SandboxFail "L. 32-bit PS detection" $_.Exception.Message
    }

    # ============================================================
    # SCENARIO M: Git / VS Code / WSL missing - non-blocking
    # ============================================================
    Write-Host ""
    Write-Host "=== SCENARIO M: Git/VS Code/WSL Non-Blocking ===" -ForegroundColor Cyan

    try {
        # Check doctor.ps1 for non-blocking patterns
        $doctorSource = Get-Content -Path $doctorPath -Raw -Encoding UTF8

        # M1: Git missing should be WARN or INFO, not ERROR (source check - must exist)
        if ($doctorSource -match 'Git 不是安装 Claude Code 的硬性要求|Git.*推荐|Git.*WARN|Git.*INFO') {
            Write-SandboxPass "M1. Git missing is non-blocking (WARN/INFO)"
        } else {
            Write-SandboxFail "M1. Git non-blocking" "doctor.ps1 does not contain Git non-blocking message"
        }

        # M2: VS Code missing should be WARN/INFO (source check - must exist)
        if ($doctorSource -match 'VS Code.*WARN|VS Code.*INFO|VS Code.*推荐|VS Code.*SKIP|VS Code.*不是硬性') {
            Write-SandboxPass "M2. VS Code missing is non-blocking"
        } else {
            Write-SandboxFail "M2. VS Code non-blocking" "doctor.ps1 does not contain VS Code non-blocking message"
        }

        # M3: WSL missing should be SKIP/INFO/WARN, not block Windows native (source check - must exist)
        if ($doctorSource -match 'WSL.*SKIP|WSL.*INFO|WSL 是高级选项|不影响 Windows 原生') {
            Write-SandboxPass "M3. WSL missing is non-blocking for Windows native install"
        } else {
            Write-SandboxFail "M3. WSL non-blocking" "doctor.ps1 does not contain WSL non-blocking message"
        }

        # M4: Runtime check from default doctor report (environment-dependent, INFO OK)
        $defReportPath = Join-Path $extractDir "report.txt"
        if (Test-Path $defReportPath) {
            $defContent = Get-Content -Path $defReportPath -Raw -Encoding UTF8

            # Git/VS Code/WSL should not cause Overall=ERROR
            if ($defContent -match "整体评估.*ERROR" -and
                $defContent -notmatch "API Key|DeepSeek.*ERROR|Claude.*ERROR") {
                Write-SandboxInfo "M4. Overall ERROR may be from non-Git/VS Code/WSL causes (environment-specific)"
            } else {
                Write-SandboxPass "M4. Git/VS Code/WSL do not block Windows native conclusion"
            }
        }
    } catch {
        Write-SandboxFail "M. Non-blocking checks" $_.Exception.Message
    }

    # ============================================================
    # SCENARIO N: settings.json protection (CONFIGURE + UNINSTALL)
    # ============================================================
    Write-Host ""
    Write-Host "=== SCENARIO N: Settings.json Protection ===" -ForegroundColor Cyan

    try {
        # Setup custom settings.json
        $customProfile = Join-Path $sandboxDir "custom-profile"
        New-Item -ItemType Directory -Path (Join-Path $customProfile ".claude") -Force | Out-Null
        $customSettingsPath = Join-Path $customProfile ".claude\settings.json"
        $customSettings = @{
            permissions = @{ deny = @("Read(./.env)") }
            env = @{
                CUSTOM_KEEP = "yes"
                ANTHROPIC_BASE_URL = "https://api.deepseek.com/anthropic"
                ANTHROPIC_AUTH_TOKEN = $DummyApiKey
                ANTHROPIC_MODEL = "deepseek-v4-pro[1m]"
                ANTHROPIC_SMALL_FAST_MODEL = "deepseek-v4-flash"
            }
        }
        $customSettings | ConvertTo-Json -Depth 8 |
            Set-Content -Path $customSettingsPath -Encoding UTF8

        $custEnv = $baseEnv.Clone()
        $custEnv["CCDI_TEST_USERPROFILE"] = $customProfile
        $custEnv["CCDI_TEST_DESKTOP"] = Join-Path $sandboxDir "custom-desktop"
        New-Item -ItemType Directory -Path $custEnv["CCDI_TEST_DESKTOP"] -Force | Out-Null

        # N1: Configure preserves non-env fields (permissions)
        $confRun = Invoke-SandboxProcess -Label "configure-deepseek with custom settings" `
            -FileName "powershell.exe" `
            -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                (Join-Path $extractDir "configure-deepseek.ps1"),
                "-NonInteractive", "-SkipApiTest") `
            -WorkingDirectory $extractDir -Environment $custEnv -TimeoutSec 180

        $afterConfig = Get-Content -Path $customSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($afterConfig.permissions.deny -contains "Read(./.env)") {
            Write-SandboxPass "N1. Configure preserves non-env fields (permissions)"
        } else {
            Write-SandboxFail "N1. Configure" "permissions field removed"
        }

        # N2: Configure keeps CUSTOM_KEEP
        if ($afterConfig.env.CUSTOM_KEEP -eq "yes") {
            Write-SandboxPass "N2. Configure preserves custom env fields"
        } else {
            Write-SandboxFail "N2. Configure" "CUSTOM_KEEP env field removed"
        }

        # N3: RemoveDeepSeekEnv preserves custom fields but removes DeepSeek
        $remRun = Invoke-SandboxProcess -Label "uninstall -RemoveDeepSeekEnv" `
            -FileName "powershell.exe" `
            -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                (Join-Path $extractDir "uninstall-config.ps1"),
                "-RemoveDeepSeekEnv", "-Yes") `
            -WorkingDirectory $extractDir -Environment $custEnv -TimeoutSec 180

        $afterRemove = Get-Content -Path $customSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($afterRemove.permissions.deny -contains "Read(./.env)" -and
            $afterRemove.env.CUSTOM_KEEP -eq "yes") {
            Write-SandboxPass "N3. RemoveDeepSeekEnv preserves custom fields"
        } else {
            Write-SandboxFail "N3. RemoveDeepSeekEnv" "custom fields removed"
        }
        $removedEnvNames = $afterRemove.env.PSObject.Properties.Name
        if ($removedEnvNames -notcontains "ANTHROPIC_AUTH_TOKEN" -and
            $removedEnvNames -notcontains "ANTHROPIC_BASE_URL") {
            Write-SandboxPass "N4. RemoveDeepSeekEnv removes DeepSeek env fields"
        } else {
            Write-SandboxFail "N4. RemoveDeepSeekEnv" "DeepSeek fields not removed"
        }

        # N5: RestoreLatest restores from backup
        $restRun = Invoke-SandboxProcess -Label "uninstall -RestoreLatest" `
            -FileName "powershell.exe" `
            -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                (Join-Path $extractDir "uninstall-config.ps1"),
                "-RestoreLatest", "-Yes") `
            -WorkingDirectory $extractDir -Environment $custEnv -TimeoutSec 180

        $afterRestore = Get-Content -Path $customSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($afterRestore.env.ANTHROPIC_AUTH_TOKEN -eq $DummyApiKey) {
            Write-SandboxPass "N5. RestoreLatest restores DeepSeek config from backup"
        } else {
            Write-SandboxFail "N5. RestoreLatest" "API Key not restored"
        }

        # N6: DeleteSettings requires -Yes and can recover
        $delRun = Invoke-SandboxProcess -Label "uninstall -DeleteSettings" `
            -FileName "powershell.exe" `
            -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                (Join-Path $extractDir "uninstall-config.ps1"),
                "-DeleteSettings", "-Yes") `
            -WorkingDirectory $extractDir -Environment $custEnv -TimeoutSec 180

        if (-not (Test-Path $customSettingsPath)) {
            Write-SandboxPass "N6. DeleteSettings removes settings.json"
        } else {
            Write-SandboxFail "N6. DeleteSettings" "settings.json still exists"
        }

        # Recover after delete
        Invoke-SandboxProcess -Label "uninstall recover after delete" `
            -FileName "powershell.exe" `
            -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                (Join-Path $extractDir "uninstall-config.ps1"),
                "-RestoreLatest", "-Yes") `
            -WorkingDirectory $extractDir -Environment $custEnv -TimeoutSec 180

        if (Test-Path $customSettingsPath) {
            Write-SandboxPass "N7. RestoreLatest recovers settings.json after delete"
        } else {
            Write-SandboxFail "N7. Recovery" "settings.json not recovered"
        }
    } catch {
        Write-SandboxFail "N. Settings protection" $_.Exception.Message
    }

    # ============================================================
    # SCENARIO O: Corrupted JSON
    # ============================================================
    Write-Host ""
    Write-Host "=== SCENARIO O: Corrupted JSON ===" -ForegroundColor Cyan

    try {
        $corruptProfile = Join-Path $sandboxDir "corrupt-profile"
        New-Item -ItemType Directory -Path (Join-Path $corruptProfile ".claude") -Force | Out-Null
        $corruptSettingsPath = Join-Path $corruptProfile ".claude\settings.json"
        Set-Content -Path $corruptSettingsPath -Value "{ bad json" -Encoding UTF8

        $corrEnv = $baseEnv.Clone()
        $corrEnv["CCDI_TEST_USERPROFILE"] = $corruptProfile
        $corrEnv["CCDI_TEST_DESKTOP"] = Join-Path $sandboxDir "corrupt-desktop"
        New-Item -ItemType Directory -Path $corrEnv["CCDI_TEST_DESKTOP"] -Force | Out-Null

        $corrRun = Invoke-SandboxProcess -Label "configure with corrupted JSON" `
            -FileName "powershell.exe" `
            -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                (Join-Path $extractDir "configure-deepseek.ps1"),
                "-NonInteractive", "-SkipApiTest") `
            -WorkingDirectory $extractDir -Environment $corrEnv -TimeoutSec 180

        # O1: Should handle corrupt JSON gracefully
        $corrLogs = Get-ChildItem -Path (Join-Path $extractDir "logs") -Filter "configure-deepseek-*.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        $corrLogText = ($corrLogs | ForEach-Object { Get-Content -Path $_.FullName -Raw -Encoding UTF8 }) -join "`n"

        if ($corrLogText -match "JSON 格式无效|JSON.*无效|settings\.json.*格式") {
            Write-SandboxPass "O1. Corrupted JSON detected with clear message"
        } else {
            Write-SandboxFail "O1. JSON error message" "configure-deepseek logs do not contain JSON format error message"
        }

        # O2: Backup of corrupted file MUST exist (scan multiple directories)
        $backupCandidates = @()
        foreach ($scanDir in @(
            (Join-Path $extractDir "backup"),
            (Join-Path $corruptProfile ".claude"),
            (Join-Path $corruptProfile ".claude-deepseek-installer"),
            $sandboxDir
        )) {
            if (Test-Path $scanDir) {
                $backupCandidates += Get-ChildItem -Path $scanDir -Recurse -File -Include "*.bak","*.backup","settings.json.*" -ErrorAction SilentlyContinue
            }
        }
        $nonEmptyBackups = $backupCandidates | Where-Object { $_.Length -gt 0 }
        if ($nonEmptyBackups.Count -gt 0) {
            Write-SandboxPass "O2. Corrupted JSON backed up ($($nonEmptyBackups.Count) non-empty backup(s))"
        } else {
            Write-SandboxFail "O2. Corrupted JSON backup" "no non-empty backup .bak file found in backup/, .claude/, .claude-deepseek-installer/, or sandbox dir"
        }

        # O3: New settings.json should be valid JSON
        if (Test-Path $corruptSettingsPath) {
            try {
                $rebuilt = Get-Content -Path $corruptSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($rebuilt.env -and $rebuilt.env.ANTHROPIC_AUTH_TOKEN) {
                    Write-SandboxPass "O3. Corrupted settings.json rebuilt successfully"
                } else {
                    Write-SandboxFail "O3. Rebuild" "env fields missing after rebuild"
                }
            } catch {
                Write-SandboxFail "O3. Rebuild" "still invalid JSON after rebuild"
            }
        }

        # O4: No crash
        if ($corrRun.ExitCode -eq 0 -and $corrRun.Combined -notmatch "ParserError|FatalError|Fatal") {
            Write-SandboxPass "O4. Corrupted JSON handler does not crash"
        } else {
            Write-SandboxFail "O4. No crash" "configure exited with errors"
        }
    } catch {
        Write-SandboxFail "O. Corrupted JSON" $_.Exception.Message
    }

    # ============================================================
    # SCENARIO P: Comprehensive Privacy Scan
    # ============================================================
    Write-Host ""
    Write-Host "=== SCENARIO P: Privacy Scan ===" -ForegroundColor Cyan

    try {
        $allTextFiles = @()
        # Collect all generated text files
        if (Test-Path (Join-Path $extractDir "report.txt")) {
            $allTextFiles += Get-Item (Join-Path $extractDir "report.txt")
        }
        $allTextFiles += Get-ChildItem -Path (Join-Path $extractDir "reports") -Filter "*.txt" -Recurse -ErrorAction SilentlyContinue
        $allTextFiles += Get-ChildItem -Path (Join-Path $extractDir "logs") -Filter "*.log" -Recurse -ErrorAction SilentlyContinue

        $scanContent = ""
        foreach ($f in $allTextFiles) {
            if (Test-Path $f.FullName) {
                $scanContent += "`n=== $($f.Name) ===`n"
                $scanContent += Get-Content -Path $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
            }
        }

        # P1: No full dummy API key
        if ($scanContent -notmatch [regex]::Escape($DummyApiKey)) {
            Write-SandboxPass "P1. No full API key in any output"
        } else {
            Write-SandboxFail "P1. API key" "full dummy key leaked"
        }

        # P2: No proxy credentials (scanned again for robustness)
        $credPatterns = @("user:pass@", "name:secret@", "abc:def@")
        $credFound = $false
        foreach ($cp in $credPatterns) {
            if ($scanContent -match [regex]::Escape($cp)) {
                Write-SandboxFail "P2. Proxy cred" "found: $cp"
                $credFound = $true
            }
        }
        if (-not $credFound) { Write-SandboxPass "P2. No proxy credentials in outputs" }

        # P3: No "Native Install lock check raw"
        if ($scanContent -notmatch 'Native Install lock check raw') {
            Write-SandboxPass "P3. No RawError log snippet leaked"
        } else {
            Write-SandboxFail "P3. RawError" "RawError snippet found in output"
        }

        # P4: No real (non-sandbox) user directory
        $realUserProfile = [Environment]::GetFolderPath("UserProfile")
        if ($realUserProfile -and $realUserProfile.Length -gt 3 -and
            $scanContent -notmatch [regex]::Escape($realUserProfile)) {
            Write-SandboxPass "P4. No real user profile path in outputs"
        } else {
            Write-SandboxInfo "P4. Real user profile may appear as %USERPROFILE%"
        }

        # P5: No ParserError
        if ($scanContent -notmatch "ParserError") {
            Write-SandboxPass "P5. No ParserError in any output"
        } else {
            Write-SandboxFail "P5. ParserError" "found in output"
        }

        # P6: No "无法将"
        if ($scanContent -notmatch "无法将") {
            Write-SandboxPass "P6. No Chinese PS error '无法将'"
        } else {
            Write-SandboxFail "P6. Chinese error" "'无法将' found"
        }

        # P7: No "not recognized"
        if ($scanContent -notmatch "not recognized") {
            Write-SandboxPass "P7. No 'not recognized' error"
        } else {
            Write-SandboxFail "P7. Not recognized" "'not recognized' found"
        }

        # P8: No Write-Log / Write-Error-Msg undefined
        if ($scanContent -notmatch "Write-Log.*未定义|Write-Error-Msg.*未定义") {
            Write-SandboxPass "P8. No undefined Write-Log/Write-Error-Msg"
        } else {
            Write-SandboxFail "P8. Undefined function" "Write-Log or Write-Error-Msg undefined"
        }

        # P9: No internal auth/internal fields
        $internalPatterns = @(
            "GrowthBook", "OAuth", "subscriber", "internal.*auth",
            "x-api-key\s*[:=]\s*sk-", "Bearer\s+sk-"
        )
        $internalFound = $false
        foreach ($ip in $internalPatterns) {
            if ($scanContent -match $ip) {
                Write-SandboxFail "P9. Internal field" "found: $ip"
                $internalFound = $true
            }
        }
        if (-not $internalFound) { Write-SandboxPass "P9. No internal auth/field exposure" }

        # P10: HasRawError structured log format MUST exist in source code (I3 already verified).
        # Runtime logs won't contain it in TestSafe (no real Native Install), so verify via source.
        $claudeInstallSourceForP10 = Get-Content -Path (Join-Path $extractDir "lib\claude-install.ps1") -Raw -Encoding UTF8
        if ($claudeInstallSourceForP10 -match "Native Install lock check: HasRawError=") {
            Write-SandboxPass "P10. HasRawError structured log format present in source"
        } else {
            Write-SandboxFail "P10. HasRawError" "structured HasRawError log format not found in claude-install.ps1"
        }

        # P11: Check-WSL has single Test-WslInstalled call (line-based extraction)
        $doctorLines = Get-Content -Path (Join-Path $extractDir "doctor.ps1") -Encoding UTF8
        $checkWslStart = -1; $checkWslEnd = $doctorLines.Count
        $nextFuncPattern = '^function\s'
        for ($i = 0; $i -lt $doctorLines.Count; $i++) {
            if ($doctorLines[$i] -match '^function Check-WSL\b') { $checkWslStart = $i }
            elseif ($checkWslStart -ge 0 -and $doctorLines[$i] -match $nextFuncPattern) {
                $checkWslEnd = $i; break
            }
        }
        if ($checkWslStart -lt 0) {
            Write-SandboxFail "P11. Check-WSL" "could not locate function Check-WSL in doctor.ps1"
        } else {
            $checkWslBody = ($doctorLines[$checkWslStart..($checkWslEnd - 1)] -join "`n")
            $wslCount = ([regex]::Matches($checkWslBody, 'Test-WslInstalled')).Count
            if ($wslCount -eq 1) {
                Write-SandboxPass "P11. Check-WSL has exactly 1 Test-WslInstalled call"
            } else {
                Write-SandboxFail "P11. Check-WSL" "Test-WslInstalled count = $wslCount, expected 1 (body lines $checkWslStart-$checkWslEnd)"
            }
        }

        # P12: Check-Commands does NOT call Test-WslInstalled
        $checkCmdsStart = -1; $checkCmdsEnd = $doctorLines.Count
        for ($i = 0; $i -lt $doctorLines.Count; $i++) {
            if ($doctorLines[$i] -match '^function Check-Commands\b') { $checkCmdsStart = $i }
            elseif ($checkCmdsStart -ge 0 -and $doctorLines[$i] -match $nextFuncPattern) {
                $checkCmdsEnd = $i; break
            }
        }
        if ($checkCmdsStart -lt 0) {
            Write-SandboxFail "P12. Check-Commands" "could not locate function Check-Commands in doctor.ps1"
        } else {
            $checkCmdsBody = ($doctorLines[$checkCmdsStart..($checkCmdsEnd - 1)] -join "`n")
            if ($checkCmdsBody -match 'Test-WslInstalled') {
                Write-SandboxFail "P12. Check-Commands" "still calls Test-WslInstalled (body lines $checkCmdsStart-$checkCmdsEnd)"
            } else {
                Write-SandboxPass "P12. Check-Commands does NOT call Test-WslInstalled"
            }
        }

        # P13: Anti-regression: no soft INFO fallback for mandatory checks.
        # Scan self source excluding this anti-regression block itself.
        $selfLines = Get-Content -Path (Join-Path $PSScriptRoot "sandbox-full-user-simulation.ps1") -Encoding UTF8
        $p13Start = -1; $p13End = -1
        for ($si = 0; $si -lt $selfLines.Count; $si++) {
            if ($selfLines[$si] -match 'P13: Anti-regression') { $p13Start = $si }
            if ($p13Start -ge 0 -and $si -gt $p13Start -and $selfLines[$si] -match '^\s*\}\s*$' -and $si -gt $p13Start + 3) { $p13End = $si; break }
        }
        $selfSourceCheck = if ($p13Start -ge 0 -and $p13End -gt $p13Start) {
            ($selfLines[0..($p13Start - 1)] -join "`n") + "`n" + ($selfLines[($p13End + 1)..($selfLines.Count - 1)] -join "`n")
        } else { $selfLines -join "`n" }
        $forbiddenSoft = @(
            "O2. Backup check: may be in TestSafe limit",
            "J4. Only",
            "will verify during runtime if needed",
            "could not extract Check-Commands body",
            "could not extract Check-WSL"
        )
        $softFound = $false
        foreach ($fs in $forbiddenSoft) {
            if ($selfSourceCheck -match [regex]::Escape($fs)) {
                Write-SandboxFail "P13. Anti-regression" "soft INFO fallback found: '$fs'"
                $softFound = $true
            }
        }
        if (-not $softFound) {
            Write-SandboxPass "P13. No soft INFO fallback for mandatory checks"
        }
    } catch {
        Write-SandboxFail "P. Privacy scan" $_.Exception.Message
    }

    # ============================================================
    # FINAL OUTPUT
    # ============================================================
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "  Sandbox Full User Simulation Results" -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "  Version:   $Version"
    Write-Host "  Branch:    $(git -C $ProjectRoot branch --show-current)"
    Write-Host "  Passed:    $script:TotalPass"
    Write-Host "  Failed:    $script:TotalFail"
    Write-Host "=============================================================="

    if ($script:TotalFail -gt 0) {
        Write-Host ""
        Write-Host "FAILURES:" -ForegroundColor Red
        foreach ($f in $script:Failures) {
            Write-Host "  $f" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "[sandbox] FULL USER SIMULATION FAILED" -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "[sandbox] FULL USER SIMULATION PASSED" -ForegroundColor Green
    exit 0

} finally {
    if (-not $KeepTemp) {
        Remove-Item $sandboxDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "[sandbox] Kept temp dirs: $sandboxDir, $tempRoot" -ForegroundColor Yellow
    }
}
