# ============================================================
# Single-entry, single-user VM final acceptance orchestrator.
# Live is opt-in and performs real installation/API operations.
# ============================================================

[CmdletBinding()]
param(
    [ValidateSet("TestSafe", "Live")]
    [string]$Mode = "TestSafe",
    [string]$Version = "1.3.3",
    [string]$CredentialTarget = "CCDI_ACCEPTANCE_DEEPSEEK_API_KEY",
    [switch]$AcknowledgeRealInstall,
    [switch]$Resume,
    [string]$ControlRoot = "C:\CCDI-Acceptance-Control"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$environmentModule = Join-Path $PSScriptRoot "lib\AcceptanceEnvironment.ps1"
$interactiveScript = Join-Path $PSScriptRoot "interactive-user-acceptance.ps1"
$scenarioFile = Join-Path $PSScriptRoot "data\interactive-acceptance-scenarios.json"
. $environmentModule

function Write-VmAcceptance {
    param([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Cyan)
    Write-Host "[vm-acceptance] $Message" -ForegroundColor $Color
}

function ConvertTo-VmArgument {
    param([AllowNull()][string]$Argument)
    if ($null -eq $Argument -or $Argument.Length -eq 0) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"'); $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') { [void]$builder.Append(('\' * ($slashes * 2 + 1))); [void]$builder.Append('"') }
        else { if ($slashes) { [void]$builder.Append(('\' * $slashes)) }; [void]$builder.Append($character) }
        $slashes = 0
    }
    if ($slashes) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-VmStage {
    param([string]$Name, [string]$FilePath, [string[]]$Arguments, [int]$TimeoutSec, [string]$EvidenceRoot)
    $safeName = $Name -replace '[^A-Za-z0-9_-]', '-'
    $stdout = Join-Path $EvidenceRoot "$safeName.stdout.txt"
    $stderr = Join-Path $EvidenceRoot "$safeName.stderr.txt"
    $argumentLine = ($Arguments | ForEach-Object { ConvertTo-VmArgument $_ }) -join ' '
    $started = Get-Date
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $argumentLine
    $psi.WorkingDirectory = $ProjectRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($psi)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSec * 1000)) {
        try { & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null } catch { }
        throw "$Name timed out after ${TimeoutSec}s"
    }
    [void]$outTask.Wait(5000); [void]$errTask.Wait(5000)
    [IO.File]::WriteAllText($stdout, $outTask.Result, (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($stderr, $errTask.Result, (New-Object Text.UTF8Encoding($false)))
    $result = [ordered]@{ Name = $Name; ExitCode = $process.ExitCode; DurationSec = [Math]::Round(((Get-Date) - $started).TotalSeconds, 2); Stdout = $stdout; Stderr = $stderr }
    if ($process.ExitCode -ne 0) { throw "$Name failed with exit code $($process.ExitCode); stdout=$stdout stderr=$stderr" }
    return $result
}

function Assert-VmLiveGate {
    param([string]$ZipPath)
    if ($Mode -ne "Live") { return }
    if (-not $AcknowledgeRealInstall) { throw "Live requires -Mode Live and -AcknowledgeRealInstall" }
    if (-not (Test-Path -LiteralPath "C:\CCDI-ACCEPTANCE-VM.marker" -PathType Leaf)) { throw "Live marker missing: C:\CCDI-ACCEPTANCE-VM.marker" }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Live requires an elevated administrator process" }
    $os = Get-CimInstance Win32_OperatingSystem
    if ([int]$os.BuildNumber -lt 22000) { throw "Live requires Windows 11; build=$($os.BuildNumber)" }
    $computer = Get-CimInstance Win32_ComputerSystem
    if ("$($computer.Manufacturer) $($computer.Model)" -notmatch 'VMware') { throw "Live requires a VMware VM" }
    if (-not (([IO.Path]::GetFullPath((Get-Location).Path)).StartsWith([IO.Path]::GetFullPath($ProjectRoot), [StringComparison]::OrdinalIgnoreCase) -or
        (Test-Path -LiteralPath $ZipPath -PathType Leaf))) { throw "Live must run from this project or an existing final ZIP" }
}

function Get-ProtectedProcessIds {
    $ids = New-Object System.Collections.ArrayList
    $current = $PID
    while ($current -gt 0 -and $current -notin $ids) {
        [void]$ids.Add([int]$current)
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
        if (-not $process) { break }
        $current = [int]$process.ParentProcessId
    }
    foreach ($process in Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'codex|Code' -or $_.CommandLine -match '\\.codex|vm-final-acceptance' }) {
        [void]$ids.Add([int]$process.ProcessId)
    }
    return @($ids | Select-Object -Unique)
}

function Write-JsonFile {
    param([string]$Path, $Value)
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Start-LiveScenarioSetup {
    param($Scenario, [string]$SceneDir)
    $state = [ordered]@{ HostsBytes = $null; RenamedFiles = @(); AddedPath = $null; FaultBin = $null }
    if (-not ($Scenario.PSObject.Properties.Name -contains "setup")) { return $state }
    $setup = $Scenario.setup
    try {
    if ($setup.PSObject.Properties.Name -contains "blockOfficialEndpoints" -and $setup.blockOfficialEndpoints) {
        $hostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
        $state.HostsBytes = [IO.File]::ReadAllBytes($hostsPath)
        Add-Content -LiteralPath $hostsPath -Encoding ASCII -Value "`r`n127.0.0.1 claude.ai`r`n127.0.0.1 downloads.claude.ai`r`n"
        Clear-DnsClientCache
    }
    if ($setup.PSObject.Properties.Name -contains "installNodeForFault" -and $setup.installNodeForFault) {
        $wingetCommand = Get-Command winget.exe -ErrorAction Stop | Select-Object -First 1
        $probe = Invoke-AcceptanceCapturedCommand -FilePath ([string]$wingetCommand.Source) -ArgumentList @(
            'install', '--id', 'OpenJS.NodeJS.LTS', '--exact', '--silent', '--disable-interactivity',
            '--accept-package-agreements', '--accept-source-agreements'
        ) -TimeoutSec 300
        if ($probe.TimedOut -or $probe.ExitCode -ne 0) { throw "Scenario setup failed to install Node.js LTS within the controlled timeout" }
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    }
    if ($setup.PSObject.Properties.Name -contains "hideNpm" -and $setup.hideNpm) {
        $npmCommands = @(Get-Command npm, npm.cmd, npm.ps1, npx, npx.cmd, npx.ps1 -All -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -ExpandProperty Path -Unique)
        foreach ($path in $npmCommands) {
            $hidden = "$path.ccdi-hidden"
            Move-Item -LiteralPath $path -Destination $hidden -Force
            $state.RenamedFiles += [ordered]@{ Original = $path; Hidden = $hidden }
        }
    }
    if ($setup.PSObject.Properties.Name -contains "installCommandFailsButClaudeAppears" -and $setup.installCommandFailsButClaudeAppears) {
        $realNpm = (Get-Command npm.cmd -ErrorAction Stop | Select-Object -First 1).Source
        $faultBin = Join-Path $SceneDir "fault-bin"
        New-Item -ItemType Directory -Path $faultBin -Force | Out-Null
        $npmWrapper = Join-Path $faultBin "npm.cmd"
        @"
@echo off
if /I "%1"=="install" (
  >"%~dp0claude.cmd" echo @echo off
  >>"%~dp0claude.cmd" echo echo 2.1.0 ^(Claude Code^)
  exit /b 7
)
"$realNpm" %*
"@ | Set-Content -LiteralPath $npmWrapper -Encoding ASCII
        $state.AddedPath = $faultBin
        $state.FaultBin = $faultBin
        $env:Path = "$faultBin;$env:Path"
        [Environment]::SetEnvironmentVariable("Path", "$faultBin;" + [Environment]::GetEnvironmentVariable("Path", "User"), "User")
    }
    return $state
    }
    catch {
        Stop-LiveScenarioSetup -State $state
        throw
    }
}

function Stop-LiveScenarioSetup {
    param($State)
    if ($State.HostsBytes) {
        $hostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
        [IO.File]::WriteAllBytes($hostsPath, $State.HostsBytes)
        [Array]::Clear($State.HostsBytes, 0, $State.HostsBytes.Length)
        Clear-DnsClientCache
    }
    foreach ($rename in @($State.RenamedFiles)) {
        if (Test-Path -LiteralPath $rename.Hidden) { Move-Item -LiteralPath $rename.Hidden -Destination $rename.Original -Force }
    }
}

$runId = if ($Resume) {
    $resumePath = Join-Path $ControlRoot "resume-state.json"
    if (-not (Test-Path -LiteralPath $resumePath -PathType Leaf)) { throw "Resume state not found: $resumePath" }
    [string]((Get-Content -LiteralPath $resumePath -Raw -Encoding UTF8 | ConvertFrom-Json).RunId)
} else { Get-Date -Format "yyyyMMdd-HHmmss-fff" }
$paths = Get-AcceptanceControlPaths -ControlRoot $ControlRoot -RunId $runId
foreach ($directory in @($paths.Root, $paths.Baseline, $paths.Runs, $paths.Run)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$scenarioRoot = Join-Path $paths.Run "scenarios"
$snapshotTemp = Join-Path $paths.Run "snapshot-temp"
New-Item -ItemType Directory -Path $scenarioRoot, $snapshotTemp -Force | Out-Null

$zipPath = Join-Path $ProjectRoot "release\ClaudeCode-DeepSeek-本地配置助手-v$Version.zip"
Assert-VmLiveGate -ZipPath $zipPath

$settingsBytes = $null
$baseline = $null
$nextScenarioIndex = 0
$phase = "preflight"
$allResults = New-Object System.Collections.ArrayList
$cleanupReports = New-Object System.Collections.ArrayList
$stageResults = New-Object System.Collections.ArrayList
$finalStatus = "FAIL"
$errorMessage = $null
$protectedPids = Get-ProtectedProcessIds

try {
    if ($Resume) {
        $resumeState = Get-Content -LiteralPath $paths.ResumeState -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$resumeState.Mode -ne $Mode) { throw "Resume mode mismatch" }
        $nextScenarioIndex = [int]$resumeState.NextScenarioIndex
        $phase = [string]$resumeState.Phase
        $baseline = Get-Content -LiteralPath (Join-Path $paths.Baseline "baseline-before.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $settingsBackup = Join-Path $paths.Baseline "settings.json.bytes"
        if ($baseline.Settings.Exists) { $settingsBytes = [IO.File]::ReadAllBytes($settingsBackup) }
        Remove-AcceptanceResume -Paths $paths
    }
    else {
        Write-VmAcceptance "Capturing single-user baseline"
        $baseline = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp
        if ($Mode -eq "Live") {
            $preexistingRequiredCleanCommands = @($baseline.Commands | Where-Object { $_.Name -in @("claude", "node", "npm") -and $_.Exists })
            if ($preexistingRequiredCleanCommands.Count -gt 0) {
                throw "Live baseline must start without claude/node/npm: $(@($preexistingRequiredCleanCommands.Name) -join ', ')"
            }
        }
        Write-JsonFile -Path (Join-Path $paths.Baseline "baseline-before.json") -Value $baseline
        Write-JsonFile -Path (Join-Path $paths.Run "baseline-before.json") -Value $baseline
        if ($baseline.Settings.Exists) {
            $settingsBytes = [IO.File]::ReadAllBytes([string]$baseline.Settings.Path)
            [IO.File]::WriteAllBytes((Join-Path $paths.Baseline "settings.json.bytes"), $settingsBytes)
        }

        $phase = "static-validation"
        [void]$stageResults.Add((Invoke-VmStage -Name "validate-full" -FilePath "powershell.exe" -Arguments @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "validate.ps1"), "-Mode", "Full", "-Version", $Version
        ) -TimeoutSec 900 -EvidenceRoot $paths.Run))
        [void]$stageResults.Add((Invoke-VmStage -Name "validate-release" -FilePath "powershell.exe" -Arguments @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "validate.ps1"), "-Mode", "Release", "-Version", $Version
        ) -TimeoutSec 1800 -EvidenceRoot $paths.Run))
        [void]$stageResults.Add((Invoke-VmStage -Name "validate-hardcore" -FilePath "powershell.exe" -Arguments @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "validate.ps1"), "-Mode", "Hardcore", "-Version", $Version
        ) -TimeoutSec 900 -EvidenceRoot $paths.Run))
        [void]$stageResults.Add((Invoke-VmStage -Name "build-release" -FilePath "powershell.exe" -Arguments @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "build-release.ps1"), "-Version", $Version
        ) -TimeoutSec 300 -EvidenceRoot $paths.Run))
    }

    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) { throw "Final ZIP missing: $zipPath" }
    Assert-VmLiveGate -ZipPath $zipPath

    $scenarioDocument = Get-Content -LiteralPath $scenarioFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $testSafeScenarios = @($scenarioDocument.scenarioSets.TestSafe)
    $liveScenarios = if ($Mode -eq "Live") { @($scenarioDocument.scenarioSets.Live) } else { @() }
    $orderedScenarios = @($testSafeScenarios) + @($liveScenarios)
    for ($index = $nextScenarioIndex; $index -lt $orderedScenarios.Count; $index++) {
        $scenario = $orderedScenarios[$index]
        $scenarioMode = if ($index -lt $testSafeScenarios.Count) { "TestSafe" } else { "Live" }
        $scenarioId = [string]$scenario.id
        $sceneDir = Join-Path $scenarioRoot $scenarioId
        New-Item -ItemType Directory -Path $sceneDir -Force | Out-Null
        Write-VmAcceptance "Scenario $($index + 1)/$($orderedScenarios.Count): $scenarioId ($scenarioMode)"

        $phase = "scenario-pre-cleanup"
        $pre = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp
        $preDelta = Compare-AcceptanceSnapshot -Before $baseline -After $pre
        $preEquivalent = Test-AcceptanceBaselineEquivalent -Baseline $baseline -Candidate $pre
        if (-not $preEquivalent.Equivalent) {
            $preReset = Reset-AcceptanceEnvironment -Baseline $baseline -Current $pre -Delta $preDelta -SettingsBytes $settingsBytes `
                -ProjectRoot $ProjectRoot -ControlRoot $paths.Root -ResultRoot $paths.Run `
                -AllowedCleanupRoots (Get-AcceptanceKnownRoots) -ProtectedProcessIds $protectedPids
            [void]$cleanupReports.Add([ordered]@{ Scenario = $scenarioId; Phase = "before"; Report = $preReset })
            if (-not $preReset.Success) { throw "Pre-scenario cleanup failed: $($preReset.Errors -join '; ')" }
            $pre = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp
            $preEquivalent = Test-AcceptanceBaselineEquivalent -Baseline $baseline -Candidate $pre
            if (-not $preEquivalent.Equivalent) { throw "Environment differs from baseline before $scenarioId`: $($preEquivalent.Differences -join '; ')" }
        }

        $phase = "scenario-run"
        $arguments = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $interactiveScript,
            "-Mode", $scenarioMode, "-Version", $Version, "-ScenarioId", $scenarioId,
            "-SourceZip", $zipPath, "-SkipBuild", "-RunRoot", (Join-Path $sceneDir "runner")
        )
        if ($index -gt 0) { $arguments += "-SkipDriverSelfTest" }
        if ($scenarioMode -eq "Live") { $arguments += @("-CredentialTarget", $CredentialTarget, "-AcknowledgeRealInstall") }
        $setupState = $null
        $scenarioResult = $null
        $scenarioFailure = $null
        try {
            if ($scenarioMode -eq "Live") { $setupState = Start-LiveScenarioSetup -Scenario $scenario -SceneDir $sceneDir }
            $scenarioResult = Invoke-VmStage -Name ("scenario-" + $scenarioId) -FilePath "powershell.exe" -Arguments $arguments `
                -TimeoutSec $(if ($scenarioMode -eq "Live") { 2400 } else { 600 }) -EvidenceRoot $sceneDir
        }
        catch {
            $scenarioFailure = $_.Exception.Message
        }
        finally {
            if ($setupState) { Stop-LiveScenarioSetup -State $setupState }
        }
        [void]$allResults.Add([ordered]@{
            Id = $scenarioId
            Mode = $scenarioMode
            Status = if ($scenarioFailure) { "FAIL" } else { "PASS" }
            Stage = $scenarioResult
            Error = $scenarioFailure
        })

        $phase = "scenario-post-cleanup"
        $post = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp
        $delta = Compare-AcceptanceSnapshot -Before $baseline -After $post
        Write-JsonFile -Path (Join-Path $sceneDir "ownership-delta.json") -Value $delta
        $cleanup = Reset-AcceptanceEnvironment -Baseline $baseline -Current $post -Delta $delta -SettingsBytes $settingsBytes `
            -ProjectRoot $ProjectRoot -ControlRoot $paths.Root -ResultRoot $paths.Run `
            -AllowedCleanupRoots (Get-AcceptanceKnownRoots) -ProtectedProcessIds $protectedPids
        [void]$cleanupReports.Add([ordered]@{ Scenario = $scenarioId; Phase = "after"; Report = $cleanup })
        if (-not $cleanup.Success) {
            $lockOnly = @($cleanup.Errors | Where-Object { $_ -notmatch '^LOCKED_PATH:' }).Count -eq 0
            if ($lockOnly) {
                $resume = [ordered]@{ RunId = $runId; Mode = $Mode; Version = $Version; Phase = $phase; NextScenarioIndex = $index; Error = ($cleanup.Errors -join '; ') }
                Register-AcceptanceResume -Paths $paths -EntryScript $PSCommandPath -State $resume
                Restart-Computer -Force
                exit 194
            }
            throw "Cleanup failed: $($cleanup.Errors -join '; ')"
        }
        $afterCleanup = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp
        $equivalence = Test-AcceptanceBaselineEquivalent -Baseline $baseline -Candidate $afterCleanup
        if (-not $equivalence.Equivalent) { throw "Residual state after $scenarioId`: $($equivalence.Differences -join '; ')" }
        if ($scenarioFailure) { throw "Scenario $scenarioId failed after cleanup: $scenarioFailure" }
        $nextScenarioIndex = $index + 1
    }

    $baselineAfter = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp
    Write-JsonFile -Path (Join-Path $paths.Run "baseline-after.json") -Value $baselineAfter
    $finalCompare = Test-AcceptanceBaselineEquivalent -Baseline $baseline -Candidate $baselineAfter
    if (-not $finalCompare.Equivalent) { throw "Final environment differs from baseline: $($finalCompare.Differences -join '; ')" }

    $phase = "leak-scan"
    $transcripts = Get-ChildItem -LiteralPath $paths.Run -Filter "transcript.txt" -File -Recurse -ErrorAction SilentlyContinue
    $sanitizedTranscript = Join-Path $paths.Run "sanitized-transcript.txt"
    foreach ($transcript in $transcripts) {
        "===== $($transcript.FullName) =====" | Add-Content -LiteralPath $sanitizedTranscript -Encoding UTF8
        Get-Content -LiteralPath $transcript.FullName -Encoding UTF8 | Add-Content -LiteralPath $sanitizedTranscript -Encoding UTF8
    }
    $leakFiles = @(Get-ChildItem -LiteralPath $paths.Run -File -Recurse -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -in @('.txt', '.json', '.log', '.md', '.ps1', '.cmd', '.csv', '.xml', '.yml', '.yaml')
    })
    $leaks = New-Object System.Collections.ArrayList
    if ($Mode -eq "Live") {
        Add-Type -Path (Join-Path $PSScriptRoot "lib\ConPtyAcceptanceHost.cs") -ErrorAction SilentlyContinue
        $realSecret = [Ccdi.Acceptance.WindowsCredential]::ReadGeneric($CredentialTarget)
        foreach ($file in $leakFiles) {
            $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
            if ($text -and $text.Contains($realSecret)) { [void]$leaks.Add($file.FullName) }
        }
        $realSecret = $null
    }
    $leakReport = [ordered]@{ ScannedFiles = $leakFiles.Count; SecretOccurrences = $leaks.Count; Files = @($leaks) }
    Write-JsonFile -Path (Join-Path $paths.Run "leak-scan-report.json") -Value $leakReport
    if ($leaks.Count -gt 0) { throw "API Key leaked into acceptance artifacts" }

    $finalStatus = "PASS"
}
catch {
    $errorMessage = $_.Exception.Message
    if ($baseline) {
        try {
            $failureCurrent = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp
            $failureDelta = Compare-AcceptanceSnapshot -Before $baseline -After $failureCurrent
            $failureCleanup = Reset-AcceptanceEnvironment -Baseline $baseline -Current $failureCurrent -Delta $failureDelta -SettingsBytes $settingsBytes `
                -ProjectRoot $ProjectRoot -ControlRoot $paths.Root -ResultRoot $paths.Run `
                -AllowedCleanupRoots (Get-AcceptanceKnownRoots) -ProtectedProcessIds $protectedPids
            [void]$cleanupReports.Add([ordered]@{ Scenario = "__failure__"; Phase = $phase; Report = $failureCleanup })
            if (-not $failureCleanup.Success) {
                $lockOnly = @($failureCleanup.Errors | Where-Object { $_ -notmatch '^LOCKED_PATH:' }).Count -eq 0
                if ($lockOnly) {
                    $resume = [ordered]@{ RunId = $runId; Mode = $Mode; Version = $Version; Phase = $phase; NextScenarioIndex = $nextScenarioIndex; Error = ($failureCleanup.Errors -join '; ') }
                    Register-AcceptanceResume -Paths $paths -EntryScript $PSCommandPath -State $resume
                    Restart-Computer -Force
                    exit 194
                }
                $errorMessage += "; failure cleanup failed: $($failureCleanup.Errors -join '; ')"
            }
            else {
                $failureAfterCleanup = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp
                Write-JsonFile -Path (Join-Path $paths.Run "baseline-after.json") -Value $failureAfterCleanup
                $failureEquivalent = Test-AcceptanceBaselineEquivalent -Baseline $baseline -Candidate $failureAfterCleanup
                if (-not $failureEquivalent.Equivalent) {
                    $errorMessage += "; residual state after failure cleanup: $($failureEquivalent.Differences -join '; ')"
                }
            }
        }
        catch {
            $errorMessage += "; failure cleanup exception: $($_.Exception.Message)"
        }
    }
}
finally {
    if ($settingsBytes) { [Array]::Clear($settingsBytes, 0, $settingsBytes.Length) }
}

Write-JsonFile -Path (Join-Path $paths.Run "scenario-results.json") -Value @($allResults)
Write-JsonFile -Path (Join-Path $paths.Run "cleanup-report.json") -Value @($cleanupReports)
$summaryFullSha = try { (& git -C $ProjectRoot rev-parse HEAD) } catch { $null }
$summaryZipSha = if (Test-Path -LiteralPath $zipPath) { (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash } else { $null }
$summary = [ordered]@{
    SchemaVersion = 1; RunId = $runId; Status = $finalStatus; Mode = $Mode; Version = $Version
    FullSHA = $summaryFullSha
    Zip = $zipPath; ZipSHA256 = $summaryZipSha
    Phase = $phase; StaticStages = @($stageResults); Scenarios = @($allResults); Error = $errorMessage; CompletedAt = (Get-Date).ToString("o")
}
Write-JsonFile -Path (Join-Path $paths.Run "summary.json") -Value $summary
@(
    "CCDI VM final acceptance", "Status: $finalStatus", "Mode: $Mode", "Version: $Version", "Full SHA: $($summary.FullSHA)",
    "ZIP SHA256: $($summary.ZipSHA256)", "Scenarios passed: $(@($allResults).Count)", "Run directory: $($paths.Run)",
    $(if ($errorMessage) { "Error: $errorMessage" } else { "" })
) | Where-Object { $_ } | Set-Content -LiteralPath (Join-Path $paths.Run "summary.txt") -Encoding UTF8

Write-VmAcceptance "Summary: $(Join-Path $paths.Run 'summary.txt')"
if ($finalStatus -ne "PASS") { Write-VmAcceptance "FAIL: $errorMessage" Red; exit 1 }
Remove-AcceptanceResume -Paths $paths
Write-VmAcceptance "PASS" Green
exit 0
