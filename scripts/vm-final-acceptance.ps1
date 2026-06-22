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
    [switch]$AcknowledgeRestart,
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
    $resultPath = Join-Path $EvidenceRoot "$safeName.result.json"
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
    $process = $null; $outTask = $null; $errTask = $null; $timedOut = $false; $exitCode = $null; $outText = ''; $errText = ''
    try {
        $process = [Diagnostics.Process]::Start($psi)
        $outTask = $process.StandardOutput.ReadToEndAsync(); $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            $timedOut = $true
            try { & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null } catch { }
            [void]$process.WaitForExit(10000)
        }
        [void]$outTask.Wait(10000); [void]$errTask.Wait(10000)
        if ($outTask.IsCompleted) { $outText = [string]$outTask.Result }
        if ($errTask.IsCompleted) { $errText = [string]$errTask.Result }
        if ($process.HasExited) { $exitCode = $process.ExitCode }
    }
    finally {
        [IO.File]::WriteAllText($stdout, $outText, (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($stderr, $errText, (New-Object Text.UTF8Encoding($false)))
        $result = [ordered]@{ Name = $Name; ExitCode = $exitCode; TimedOut = $timedOut; DurationSec = [Math]::Round(((Get-Date) - $started).TotalSeconds, 2); Stdout = $stdout; Stderr = $stderr; Result = $resultPath }
        $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8
        if ($process) { $process.Dispose() }
    }
    if ($timedOut) { throw "$Name timed out after ${TimeoutSec}s; stdout=$stdout stderr=$stderr result=$resultPath" }
    if ($exitCode -ne 0) { throw "$Name failed with exit code $exitCode; stdout=$stdout stderr=$stderr result=$resultPath" }
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

function Test-VmAutomaticRestartAllowed {
    param([string]$AcceptanceMode, [bool]$RealInstallAcknowledged, [bool]$RestartAcknowledged)
    return $AcceptanceMode -eq 'Live' -and $RealInstallAcknowledged -and $RestartAcknowledged
}

function Invoke-VmAuthorizedRestart {
    param($ResumeState)
    if (-not (Test-VmAutomaticRestartAllowed -AcceptanceMode $Mode -RealInstallAcknowledged ([bool]$AcknowledgeRealInstall) -RestartAcknowledged ([bool]$AcknowledgeRestart))) {
        throw 'Automatic restart is disabled. It requires -Mode Live, -AcknowledgeRealInstall, and -AcknowledgeRestart.'
    }
    Assert-VmLiveGate -ZipPath $zipPath
    [void](Register-AcceptanceResume -Paths $paths -EntryScript $PSCommandPath -State $ResumeState)
    Restart-Computer -Force
    exit 194
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

function New-VmPathAdapter {
    # Real-environment adapter. Live scenarios use this so the three PATH layers and npm
    # resolution touch actual machine state. Functional tests inject a sandbox adapter so
    # no permanent User/Machine PATH, real USERPROFILE, or real software is touched.
    [pscustomobject]@{ Mode = 'Real' }
}

function New-VmSandboxPathAdapter {
    param($State, [string]$NpmSource)
    [pscustomobject]@{ Mode = 'Sandbox'; State = $State; NpmSource = $NpmSource }
}

function Get-VmAdapterPath {
    param($Adapter, [ValidateSet('Process', 'User', 'Machine')][string]$Layer)
    if ($Adapter.Mode -eq 'Sandbox') { return [string]$Adapter.State[$Layer] }
    switch ($Layer) {
        'Process' { return [string]$env:Path }
        'User' { return [string][Environment]::GetEnvironmentVariable('Path', 'User') }
        'Machine' { return [string][Environment]::GetEnvironmentVariable('Path', 'Machine') }
    }
}

function Set-VmAdapterPath {
    param($Adapter, [ValidateSet('Process', 'User', 'Machine')][string]$Layer, [string]$Value)
    if ($Adapter.Mode -eq 'Sandbox') { $Adapter.State[$Layer] = $Value; return }
    switch ($Layer) {
        'Process' { $env:Path = $Value }
        'User' { [Environment]::SetEnvironmentVariable('Path', $Value, 'User') }
        'Machine' { [Environment]::SetEnvironmentVariable('Path', $Value, 'Machine') }
    }
}

function Resolve-VmAdapterNpm {
    param($Adapter)
    if ($Adapter.Mode -eq 'Sandbox') { return [pscustomobject]@{ Source = [string]$Adapter.NpmSource } }
    $cmd = Get-Command npm.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return [pscustomobject]@{ Source = [string]$cmd.Source } }
    return $null
}

function Start-LiveScenarioSetup {
    param($Scenario, [string]$SceneDir, $PathAdapter)
    if (-not $PathAdapter) { $PathAdapter = New-VmPathAdapter }
    $state = [ordered]@{
        HostsBytes = $null; RenamedFiles = @(); AddedPath = $null; FaultBin = $null
        ProcessPathBefore = Get-VmAdapterPath -Adapter $PathAdapter -Layer Process
        UserPathBefore = Get-VmAdapterPath -Adapter $PathAdapter -Layer User
        MachinePathBefore = Get-VmAdapterPath -Adapter $PathAdapter -Layer Machine
        PathAdapter = $PathAdapter
        OwnedWingetPackages = @(); OwnedNpmPackages = @(); OwnedPathRoots = @()
    }
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
        $state.OwnedWingetPackages += 'OpenJS.NodeJS.LTS'
        $state.OwnedPathRoots += (Join-Path $env:ProgramFiles 'nodejs')
        Set-VmAdapterPath -Adapter $PathAdapter -Layer Process -Value ((Get-VmAdapterPath -Adapter $PathAdapter -Layer Machine) + ';' + (Get-VmAdapterPath -Adapter $PathAdapter -Layer User))
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
        $realNpm = Resolve-VmAdapterNpm -Adapter $PathAdapter
        if (-not $realNpm) { throw "Scenario setup could not resolve npm.cmd to build the fault wrapper" }
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
"$([string]$realNpm.Source)" %*
"@ | Set-Content -LiteralPath $npmWrapper -Encoding ASCII
        $state.AddedPath = $faultBin
        $state.FaultBin = $faultBin
        $state.OwnedPathRoots += $faultBin
        Set-VmAdapterPath -Adapter $PathAdapter -Layer Process -Value ("$faultBin;" + (Get-VmAdapterPath -Adapter $PathAdapter -Layer Process))
        Set-VmAdapterPath -Adapter $PathAdapter -Layer User -Value ("$faultBin;" + (Get-VmAdapterPath -Adapter $PathAdapter -Layer User))
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
    $errors = New-Object Collections.ArrayList
    $adapter = if ($State.PathAdapter) { $State.PathAdapter } else { New-VmPathAdapter }
    try { if ((Get-VmAdapterPath -Adapter $adapter -Layer Process) -ne [string]$State.ProcessPathBefore) { Set-VmAdapterPath -Adapter $adapter -Layer Process -Value ([string]$State.ProcessPathBefore) } } catch { [void]$errors.Add("process PATH: $($_.Exception.Message)") }
    try { if ((Get-VmAdapterPath -Adapter $adapter -Layer User) -ne [string]$State.UserPathBefore) { Set-VmAdapterPath -Adapter $adapter -Layer User -Value ([string]$State.UserPathBefore) } } catch { [void]$errors.Add("user PATH: $($_.Exception.Message)") }
    try { if ((Get-VmAdapterPath -Adapter $adapter -Layer Machine) -ne [string]$State.MachinePathBefore) { Set-VmAdapterPath -Adapter $adapter -Layer Machine -Value ([string]$State.MachinePathBefore) } } catch { [void]$errors.Add("machine PATH: $($_.Exception.Message)") }
    if ($State.HostsBytes) {
        try {
        $hostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
        [IO.File]::WriteAllBytes($hostsPath, $State.HostsBytes)
        [Array]::Clear($State.HostsBytes, 0, $State.HostsBytes.Length)
        Clear-DnsClientCache
        } catch { [void]$errors.Add("hosts: $($_.Exception.Message)") }
    }
    foreach ($rename in @($State.RenamedFiles)) {
        try { if (Test-Path -LiteralPath $rename.Hidden) { Move-Item -LiteralPath $rename.Hidden -Destination $rename.Original -Force } }
        catch { [void]$errors.Add("restore $($rename.Original): $($_.Exception.Message)") }
    }
    try { if ($State.FaultBin -and (Test-Path -LiteralPath $State.FaultBin)) { Remove-Item -LiteralPath $State.FaultBin -Recurse -Force -ErrorAction Stop } }
    catch { [void]$errors.Add("fault-bin: $($_.Exception.Message)") }
    if ($errors.Count) { throw "Scenario setup restoration failed: $($errors -join '; ')" }
}

function Get-VmScenarioOwnership {
    param($Scenario, $SetupState, [ValidateSet('TestSafe', 'Live')][string]$ScenarioMode)
    $pathRoots = New-Object Collections.ArrayList
    $pathPatterns = New-Object Collections.ArrayList
    $npmPackages = New-Object Collections.ArrayList
    $wingetPackages = New-Object Collections.ArrayList
    $desktop = [Environment]::GetFolderPath('Desktop')
    # TestSafe invokes the real buyer launchers; Claude itself may update this state file.
    if ($ScenarioMode -eq 'TestSafe') { [void]$pathRoots.Add((Join-Path $env:USERPROFILE '.claude.json')) }
    $ownershipSpec = if ($Scenario.PSObject.Properties.Name -contains 'ownership') { $Scenario.ownership } else { $null }
    foreach ($kind in @($(if ($ownershipSpec) { $ownershipSpec.pathKinds } else { @() }))) {
        switch ([string]$kind) {
            'claude-runtime' {
                foreach ($path in @((Join-Path $env:USERPROFILE '.claude'), (Join-Path $env:USERPROFILE '.local\bin'), (Join-Path $env:USERPROFILE '.local\share\claude'), (Join-Path $env:LOCALAPPDATA 'Programs\claude'), (Join-Path $env:LOCALAPPDATA 'AnthropicClaude'))) { [void]$pathRoots.Add($path) }
            }
            'desktop-test' {
                [void]$pathRoots.Add((Join-Path $desktop 'ClaudeCode-Test'))
                [void]$pathPatterns.Add(('^' + [regex]::Escape(([IO.Path]::GetFullPath($desktop)).TrimEnd('\') + '\ClaudeCode-Test-') + '\d{8}-\d{6}(?:-\d+)?(?:\\|$)'))
            }
            'installer-state' { [void]$pathRoots.Add((Join-Path $env:USERPROFILE '.claude-deepseek-installer')) }
            'claude-user-json' { [void]$pathRoots.Add((Join-Path $env:USERPROFILE '.claude.json')) }
            'node-runtime' { [void]$pathRoots.Add((Join-Path $env:ProgramFiles 'nodejs')) }
            'npm-runtime' { [void]$pathRoots.Add((Join-Path $env:APPDATA 'npm')) }
        }
    }
    if ($ownershipSpec) {
        foreach ($value in @($ownershipSpec.npmPackages)) { [void]$npmPackages.Add([string]$value) }
        foreach ($value in @($ownershipSpec.wingetPackages)) { [void]$wingetPackages.Add([string]$value) }
    }
    if ($SetupState) {
        foreach ($value in @($SetupState.OwnedPathRoots)) { [void]$pathRoots.Add([string]$value) }
        foreach ($value in @($SetupState.OwnedNpmPackages)) { [void]$npmPackages.Add([string]$value) }
        foreach ($value in @($SetupState.OwnedWingetPackages)) { [void]$wingetPackages.Add([string]$value) }
    }
    New-AcceptanceOwnership -PathRoots @($pathRoots) -PathPatterns @($pathPatterns) -NpmPackages @($npmPackages) -WingetPackages @($wingetPackages)
}

function New-VmResumeState {
    param([int]$NextScenarioIndex, [string]$CurrentPhase, $PendingOwnership)
    [ordered]@{
        SchemaVersion = 3
        RunId = $runId; Mode = $Mode; Version = $Version; CredentialTarget = $CredentialTarget
        AcknowledgeRealInstall = [bool]$AcknowledgeRealInstall
        AcknowledgeRestart = [bool]$AcknowledgeRestart
        Phase = $CurrentPhase; NextScenarioIndex = $NextScenarioIndex
        StageResults = @($stageResults); ScenarioResults = @($allResults); CleanupReports = @($cleanupReports)
        PendingOwnership = $PendingOwnership; Error = $null; SavedAt = (Get-Date).ToString('o')
    }
}

if ($env:CCDI_ACCEPTANCE_IMPORT_ONLY -eq '1') { return }

$resumeBootstrapState = if ($Resume) { Read-AcceptanceResumeState -ControlRoot $ControlRoot } else { $null }
if ($resumeBootstrapState) {
    $Mode = [string]$resumeBootstrapState.Mode; $Version = [string]$resumeBootstrapState.Version
    $CredentialTarget = [string]$resumeBootstrapState.CredentialTarget
    $AcknowledgeRealInstall = [bool]$resumeBootstrapState.AcknowledgeRealInstall
    $AcknowledgeRestart = $resumeBootstrapState.PSObject.Properties.Name -contains 'AcknowledgeRestart' -and [bool]$resumeBootstrapState.AcknowledgeRestart
}
$runId = if ($Resume) { [string]$resumeBootstrapState.RunId } else { Get-Date -Format "yyyyMMdd-HHmmss-fff" }
$instanceLock = Enter-AcceptanceInstanceLock -ControlRoot $ControlRoot
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
$pendingOwnership = New-AcceptanceOwnership
$currentScenarioOwnership = New-AcceptanceOwnership

try {
    if ($Resume) {
        $resumeState = $resumeBootstrapState
        $nextScenarioIndex = [int]$resumeState.NextScenarioIndex
        $phase = [string]$resumeState.Phase
        Import-AcceptanceResumeResults -State $resumeState -StageResults $stageResults -ScenarioResults $allResults -CleanupReports $cleanupReports
        if ($resumeState.PendingOwnership) { $pendingOwnership = $resumeState.PendingOwnership }
        $baseline = Get-Content -LiteralPath (Join-Path $paths.Baseline "baseline-before.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $settingsBackup = Join-Path $paths.Baseline "settings.json.bytes"
        if ($baseline.Settings.Exists) { $settingsBytes = [IO.File]::ReadAllBytes($settingsBackup) }
        Remove-AcceptanceResume -Paths $paths -KeepState
    }
    else {
        if ($Mode -eq "Live") {
            $preexistingRequiredCleanCommands = @("claude", "node", "npm") | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue }
            if ($preexistingRequiredCleanCommands.Count -gt 0) {
                throw "Live baseline must start without claude/node/npm: $($preexistingRequiredCleanCommands -join ', ')"
            }
        }
        $phase = "static-validation"
        [void]$stageResults.Add((Invoke-VmStage -Name "acceptance-functional" -FilePath "powershell.exe" -Arguments @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "test-vm-acceptance.ps1")
        ) -TimeoutSec 300 -EvidenceRoot $paths.Run))
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

        Write-VmAcceptance "Capturing single-user scenario baseline"
        $fileBackupRoot = Join-Path $paths.Baseline 'files'
        $baseline = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp -CaptureFileBytes -FileBackupRoot $fileBackupRoot
        Assert-AcceptanceSnapshotUsable -Snapshot $baseline -Label 'Scenario baseline'
        Write-JsonFile -Path (Join-Path $paths.Baseline "baseline-before.json") -Value $baseline
        Write-JsonFile -Path (Join-Path $paths.Run "baseline-before.json") -Value $baseline
        if ($baseline.Settings.Exists) {
            $settingsBytes = [IO.File]::ReadAllBytes([string]$baseline.Settings.Path)
            [IO.File]::WriteAllBytes((Join-Path $paths.Baseline "settings.json.bytes"), $settingsBytes)
        }
    }

    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) { throw "Final ZIP missing: $zipPath" }
    Assert-VmLiveGate -ZipPath $zipPath

    $scenarioDocument = Get-Content -LiteralPath $scenarioFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $testSafeScenarios = @($scenarioDocument.scenarioSets.TestSafe)
    $liveScenarios = if ($Mode -eq "Live") { @($scenarioDocument.scenarioSets.Live) } else { @() }
    $orderedScenarios = @($testSafeScenarios) + @($liveScenarios)
    if ($Resume -and $phase -eq 'resume-cleanup-pending') {
        Write-VmAcceptance "Completing cleanup before resuming at scenario index $nextScenarioIndex"
        $protectedPids = Get-ProtectedProcessIds
        $resumeCurrent = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp
        Assert-AcceptanceSnapshotUsable -Snapshot $resumeCurrent -Label 'Resume cleanup'
        $resumeDelta = Compare-AcceptanceSnapshot -Before $baseline -After $resumeCurrent
        $resumeCleanup = Reset-AcceptanceEnvironment -Baseline $baseline -Current $resumeCurrent -Delta $resumeDelta -SettingsBytes $settingsBytes `
            -ProjectRoot $ProjectRoot -ControlRoot $paths.Root -ResultRoot $paths.Run `
            -AllowedCleanupRoots @((Get-AcceptanceKnownRoots) + @($baseline.Files.Path)) -ProtectedProcessIds $protectedPids -Ownership $pendingOwnership
        [void]$cleanupReports.Add([ordered]@{ Scenario = '__resume__'; Phase = 'resume-cleanup'; Report = $resumeCleanup })
        if (-not $resumeCleanup.Success) {
            $lockOnly = @($resumeCleanup.Errors | Where-Object { $_ -notmatch '^LOCKED_PATH:' }).Count -eq 0
            if ($lockOnly -and (Test-VmAutomaticRestartAllowed -AcceptanceMode $Mode -RealInstallAcknowledged ([bool]$AcknowledgeRealInstall) -RestartAcknowledged ([bool]$AcknowledgeRestart))) {
                $resume = New-VmResumeState -NextScenarioIndex $nextScenarioIndex -CurrentPhase 'resume-cleanup-pending' -PendingOwnership $pendingOwnership
                $resume.Error = ($resumeCleanup.Errors -join '; ')
                Invoke-VmAuthorizedRestart -ResumeState $resume
            }
            throw "Resume cleanup failed: $($resumeCleanup.Errors -join '; ')"
        }
        $resumeAfter = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp
        $resumeEquivalent = Test-AcceptanceBaselineEquivalent -Baseline $baseline -Candidate $resumeAfter -IgnoredProcessIds $protectedPids
        if (-not $resumeEquivalent.Equivalent) { throw "Resume cleanup did not restore baseline: $($resumeEquivalent.Differences -join '; ')" }
        $pendingOwnership = New-AcceptanceOwnership
        $phase = 'scenario-loop'
    }
    for ($index = $nextScenarioIndex; $index -lt $orderedScenarios.Count; $index++) {
        $scenario = $orderedScenarios[$index]
        $scenarioMode = if ($index -lt $testSafeScenarios.Count) { "TestSafe" } else { "Live" }
        $scenarioId = [string]$scenario.id
        $sceneDir = Join-Path $scenarioRoot $scenarioId
        New-Item -ItemType Directory -Path $sceneDir -Force | Out-Null
        Write-VmAcceptance "Scenario $($index + 1)/$($orderedScenarios.Count): $scenarioId ($scenarioMode)"

        $phase = "scenario-pre-cleanup"
        $protectedPids = Get-ProtectedProcessIds
        $pre = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp
        Assert-AcceptanceSnapshotUsable -Snapshot $pre -Label "Pre-scenario $scenarioId"
        $preDelta = Compare-AcceptanceSnapshot -Before $baseline -After $pre
        $preEquivalent = Test-AcceptanceBaselineEquivalent -Baseline $baseline -Candidate $pre -IgnoredProcessIds $protectedPids
        if (-not $preEquivalent.Equivalent) {
            $preReset = Reset-AcceptanceEnvironment -Baseline $baseline -Current $pre -Delta $preDelta -SettingsBytes $settingsBytes `
                -ProjectRoot $ProjectRoot -ControlRoot $paths.Root -ResultRoot $paths.Run `
                -AllowedCleanupRoots @((Get-AcceptanceKnownRoots) + @($baseline.Files.Path)) -ProtectedProcessIds $protectedPids -Ownership $pendingOwnership
            [void]$cleanupReports.Add([ordered]@{ Scenario = $scenarioId; Phase = "before"; Report = $preReset })
            if (-not $preReset.Success) { throw "Pre-scenario cleanup failed: $($preReset.Errors -join '; ')" }
            $pre = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp
            $preEquivalent = Test-AcceptanceBaselineEquivalent -Baseline $baseline -Candidate $pre -IgnoredProcessIds $protectedPids
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
            if ($setupState) {
                try { Stop-LiveScenarioSetup -State $setupState }
                catch { $scenarioFailure = if ($scenarioFailure) { "$scenarioFailure; $($_.Exception.Message)" } else { $_.Exception.Message } }
            }
        }
        $currentScenarioOwnership = Get-VmScenarioOwnership -Scenario $scenario -SetupState $setupState -ScenarioMode $scenarioMode
        [void]$allResults.Add([ordered]@{
            Id = $scenarioId
            Mode = $scenarioMode
            Status = if ($scenarioFailure) { "FAIL" } else { "PASS" }
            Stage = $scenarioResult
            Error = $scenarioFailure
        })

        $phase = "scenario-post-cleanup"
        $protectedPids = Get-ProtectedProcessIds
        $post = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp
        Assert-AcceptanceSnapshotUsable -Snapshot $post -Label "Post-scenario $scenarioId"
        $delta = Compare-AcceptanceSnapshot -Before $baseline -After $post
        Write-JsonFile -Path (Join-Path $sceneDir "ownership-delta.json") -Value $delta
        $cleanup = Reset-AcceptanceEnvironment -Baseline $baseline -Current $post -Delta $delta -SettingsBytes $settingsBytes `
            -ProjectRoot $ProjectRoot -ControlRoot $paths.Root -ResultRoot $paths.Run `
            -AllowedCleanupRoots @((Get-AcceptanceKnownRoots) + @($baseline.Files.Path)) -ProtectedProcessIds $protectedPids -Ownership $currentScenarioOwnership
        [void]$cleanupReports.Add([ordered]@{ Scenario = $scenarioId; Phase = "after"; Report = $cleanup })
        if (-not $cleanup.Success) {
            $lockOnly = @($cleanup.Errors | Where-Object { $_ -notmatch '^LOCKED_PATH:' }).Count -eq 0
            if ($lockOnly -and -not $scenarioFailure -and (Test-VmAutomaticRestartAllowed -AcceptanceMode $Mode -RealInstallAcknowledged ([bool]$AcknowledgeRealInstall) -RestartAcknowledged ([bool]$AcknowledgeRestart))) {
                $resume = New-VmResumeState -NextScenarioIndex ($index + 1) -CurrentPhase 'resume-cleanup-pending' -PendingOwnership $currentScenarioOwnership
                $resume.Error = ($cleanup.Errors -join '; ')
                Invoke-VmAuthorizedRestart -ResumeState $resume
            }
            throw "Cleanup failed: $($cleanup.Errors -join '; ')"
        }
        $afterCleanup = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp
        $equivalence = Test-AcceptanceBaselineEquivalent -Baseline $baseline -Candidate $afterCleanup -IgnoredProcessIds $protectedPids
        if (-not $equivalence.Equivalent) { throw "Residual state after $scenarioId`: $($equivalence.Differences -join '; ')" }
        if ($scenarioFailure) { throw "Scenario $scenarioId failed after cleanup: $scenarioFailure" }
        $nextScenarioIndex = $index + 1
        $pendingOwnership = New-AcceptanceOwnership
    }

    $protectedPids = Get-ProtectedProcessIds
    $baselineAfter = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp
    Write-JsonFile -Path (Join-Path $paths.Run "baseline-after.json") -Value $baselineAfter
    $finalCompare = Test-AcceptanceBaselineEquivalent -Baseline $baseline -Candidate $baselineAfter -IgnoredProcessIds $protectedPids
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
    $failedScenarioCount = @($allResults | Where-Object { $_.Status -ne 'PASS' }).Count
    if ($failedScenarioCount -gt 0) { throw "$failedScenarioCount scenario result(s) failed" }

    $finalStatus = "PASS"
}
catch {
    $errorMessage = $_.Exception.Message
    if ($baseline) {
        try {
            $protectedPids = Get-ProtectedProcessIds
            $failureCurrent = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp
            $failureDelta = Compare-AcceptanceSnapshot -Before $baseline -After $failureCurrent
            $failureCleanup = Reset-AcceptanceEnvironment -Baseline $baseline -Current $failureCurrent -Delta $failureDelta -SettingsBytes $settingsBytes `
                -ProjectRoot $ProjectRoot -ControlRoot $paths.Root -ResultRoot $paths.Run `
                -AllowedCleanupRoots @((Get-AcceptanceKnownRoots) + @($baseline.Files.Path)) -ProtectedProcessIds $protectedPids -Ownership $currentScenarioOwnership
            [void]$cleanupReports.Add([ordered]@{ Scenario = "__failure__"; Phase = $phase; Report = $failureCleanup })
            if (-not $failureCleanup.Success) {
                $lockOnly = @($failureCleanup.Errors | Where-Object { $_ -notmatch '^LOCKED_PATH:' }).Count -eq 0
                $errorMessage += "; failure cleanup failed: $($failureCleanup.Errors -join '; ')"
            }
            else {
                $failureAfterCleanup = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp
                Write-JsonFile -Path (Join-Path $paths.Run "baseline-after.json") -Value $failureAfterCleanup
                $failureEquivalent = Test-AcceptanceBaselineEquivalent -Baseline $baseline -Candidate $failureAfterCleanup -IgnoredProcessIds $protectedPids
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
$passedScenarioCount = @($allResults | Where-Object { $_.Status -eq 'PASS' }).Count
$failedScenarioCount = @($allResults | Where-Object { $_.Status -ne 'PASS' }).Count
$summary = [ordered]@{
    SchemaVersion = 1; RunId = $runId; Status = $finalStatus; Mode = $Mode; Version = $Version
    FullSHA = $summaryFullSha
    Zip = $zipPath; ZipSHA256 = $summaryZipSha
    Phase = $phase; StaticStages = @($stageResults); Scenarios = @($allResults)
    ScenariosPassed = $passedScenarioCount; ScenariosFailed = $failedScenarioCount
    Error = $errorMessage; CompletedAt = (Get-Date).ToString("o")
}
Write-JsonFile -Path (Join-Path $paths.Run "summary.json") -Value $summary
@(
    "CCDI VM final acceptance", "Status: $finalStatus", "Mode: $Mode", "Version: $Version", "Full SHA: $($summary.FullSHA)",
    "ZIP SHA256: $($summary.ZipSHA256)", "Scenarios passed: $passedScenarioCount", "Scenarios failed: $failedScenarioCount", "Run directory: $($paths.Run)",
    $(if ($errorMessage) { "Error: $errorMessage" } else { "" })
) | Where-Object { $_ } | Set-Content -LiteralPath (Join-Path $paths.Run "summary.txt") -Encoding UTF8

Write-VmAcceptance "Summary: $(Join-Path $paths.Run 'summary.txt')"
if ($finalStatus -ne "PASS") { Write-VmAcceptance "FAIL: $errorMessage" Red; Exit-AcceptanceInstanceLock -Lock $instanceLock; exit 1 }
Remove-AcceptanceResume -Paths $paths
Exit-AcceptanceInstanceLock -Lock $instanceLock
Write-VmAcceptance "PASS" Green
exit 0
