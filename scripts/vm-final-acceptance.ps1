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

function Get-VmAcceptanceCollectionCount {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return 0 }
    return @($Value).Count
}

function Invoke-VmAuthorizedRestart {
    param(
        $ResumeState,
        [string]$AcceptanceMode = $Mode,
        [bool]$RealInstallAcknowledged = [bool]$AcknowledgeRealInstall,
        [bool]$RestartAcknowledged = [bool]$AcknowledgeRestart,
        [scriptblock]$LiveGate,
        [scriptblock]$ResumeRegistrar,
        [scriptblock]$RestartInvoker
    )
    if (-not (Test-VmAutomaticRestartAllowed -AcceptanceMode $AcceptanceMode -RealInstallAcknowledged $RealInstallAcknowledged -RestartAcknowledged $RestartAcknowledged)) {
        throw 'Automatic restart is disabled. It requires -Mode Live, -AcknowledgeRealInstall, and -AcknowledgeRestart.'
    }
    if (-not $LiveGate) { $LiveGate = { Assert-VmLiveGate -ZipPath $zipPath } }
    if (-not $ResumeRegistrar) {
        $ResumeRegistrar = { param($State) Register-AcceptanceResume -Paths $paths -EntryScript $PSCommandPath -State $State -ScenarioCount $orderedScenarios.Count }
    }
    if (-not $RestartInvoker) { $RestartInvoker = { Restart-Computer -Force } }
    & $LiveGate
    $registration = & $ResumeRegistrar $ResumeState
    & $RestartInvoker
    return [PSCustomObject]@{ Registration = $registration; RestartRequested = $true }
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
    Write-AcceptanceJsonFileAtomic -Path $Path -Value $Value
}

function Get-VmStaticGuardSnapshot {
    $settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
    $settingsExists = Test-Path -LiteralPath $settingsPath -PathType Leaf
    $commands = @('claude', 'node', 'npm') | ForEach-Object {
        $command = Get-Command $_ -ErrorAction SilentlyContinue | Select-Object -First 1
        [ordered]@{ Name = $_; Exists = [bool]$command; Source = if ($command) { [string]$command.Source } else { $null } }
    }
    [PSCustomObject]@{
        UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        MachinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        ProcessPath = $env:Path
        SettingsPath = $settingsPath
        SettingsExists = $settingsExists
        SettingsLength = if ($settingsExists) { (Get-Item -LiteralPath $settingsPath -ErrorAction Stop).Length } else { 0 }
        SettingsHash = if ($settingsExists) { (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256 -ErrorAction Stop).Hash } else { $null }
        SettingsBytes = if ($settingsExists) { [IO.File]::ReadAllBytes($settingsPath) } else { $null }
        Commands = @($commands)
    }
}

function Compare-VmStaticGuardSnapshot {
    param($Before, $After)
    $differences = New-Object Collections.ArrayList
    foreach ($name in @('UserPath', 'MachinePath', 'ProcessPath', 'SettingsExists', 'SettingsLength', 'SettingsHash')) {
        if ($Before.$name -cne $After.$name) { [void]$differences.Add($name) }
    }
    if (($Before.Commands | ConvertTo-Json -Compress) -cne ($After.Commands | ConvertTo-Json -Compress)) { [void]$differences.Add('Commands') }
    return @($differences)
}

function Restore-VmStaticGuardSnapshot {
    param($Snapshot)
    $errors = New-Object Collections.ArrayList
    try { if ([Environment]::GetEnvironmentVariable('Path', 'User') -cne $Snapshot.UserPath) { [Environment]::SetEnvironmentVariable('Path', [string]$Snapshot.UserPath, 'User') } } catch { [void]$errors.Add("UserPath: $($_.Exception.Message)") }
    try { if ([Environment]::GetEnvironmentVariable('Path', 'Machine') -cne $Snapshot.MachinePath) { [Environment]::SetEnvironmentVariable('Path', [string]$Snapshot.MachinePath, 'Machine') } } catch { [void]$errors.Add("MachinePath: $($_.Exception.Message)") }
    try { if ($env:Path -cne $Snapshot.ProcessPath) { $env:Path = [string]$Snapshot.ProcessPath } } catch { [void]$errors.Add("ProcessPath: $($_.Exception.Message)") }
    try {
        if ($Snapshot.SettingsExists) {
            $parent = Split-Path -Parent $Snapshot.SettingsPath
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
            [IO.File]::WriteAllBytes([string]$Snapshot.SettingsPath, [byte[]]$Snapshot.SettingsBytes)
        }
        elseif (Test-Path -LiteralPath $Snapshot.SettingsPath) { Remove-Item -LiteralPath $Snapshot.SettingsPath -Force -ErrorAction Stop }
    }
    catch { [void]$errors.Add("settings.json: $($_.Exception.Message)") }
    if ($errors.Count) { throw "Static validation rollback failed: $($errors -join '; ')" }
}

function Write-VmSummaryArtifactsTransactional {
    param([string]$RunPath, $Summary, [string[]]$TextLines, [scriptblock]$FileWriter, [scriptblock]$Publisher)
    $jsonPath = Join-Path $RunPath 'summary.json'
    $textPath = Join-Path $RunPath 'summary.txt'
    $transactionId = [guid]::NewGuid().ToString('N')
    $jsonTemp = "$jsonPath.tmp.$transactionId"
    $textTemp = "$textPath.tmp.$transactionId"
    $jsonBackup = "$jsonPath.bak.$transactionId"
    $textBackup = "$textPath.bak.$transactionId"
    $jsonExisted = Test-Path -LiteralPath $jsonPath -PathType Leaf
    $textExisted = Test-Path -LiteralPath $textPath -PathType Leaf
    if (-not $FileWriter) {
        $FileWriter = {
            param($Path, $Value)
            [IO.File]::WriteAllText($Path, [string]$Value, (New-Object Text.UTF8Encoding($false)))
        }
    }
    if (-not $Publisher) { $Publisher = { param($Source, $Destination) Move-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop } }
    try {
        & $FileWriter $jsonTemp ($Summary | ConvertTo-Json -Depth 20)
        & $FileWriter $textTemp ($TextLines -join [Environment]::NewLine)
        if (-not (Test-Path -LiteralPath $jsonTemp -PathType Leaf) -or -not (Test-Path -LiteralPath $textTemp -PathType Leaf)) { throw 'Summary staging did not create both artifacts' }
        if ($jsonExisted) { Copy-Item -LiteralPath $jsonPath -Destination $jsonBackup -Force -ErrorAction Stop }
        if ($textExisted) { Copy-Item -LiteralPath $textPath -Destination $textBackup -Force -ErrorAction Stop }
        & $Publisher $jsonTemp $jsonPath
        & $Publisher $textTemp $textPath
        $published = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([string]$published.Status -cne [string]$Summary.Status) { throw 'Published summary status does not match the requested status' }
        $publishedText = Get-Content -LiteralPath $textPath -Raw -Encoding UTF8 -ErrorAction Stop
        if ($publishedText -notmatch ('(?m)^Status: ' + [regex]::Escape([string]$Summary.Status) + '\r?$')) { throw 'Published summary text status does not match the requested status' }
    }
    catch {
        $publishError = $_.Exception.Message
        try {
            if ($jsonExisted -and (Test-Path -LiteralPath $jsonBackup)) { Copy-Item -LiteralPath $jsonBackup -Destination $jsonPath -Force -ErrorAction Stop }
            elseif (-not $jsonExisted -and (Test-Path -LiteralPath $jsonPath)) { Remove-Item -LiteralPath $jsonPath -Force -ErrorAction Stop }
            if ($textExisted -and (Test-Path -LiteralPath $textBackup)) { Copy-Item -LiteralPath $textBackup -Destination $textPath -Force -ErrorAction Stop }
            elseif (-not $textExisted -and (Test-Path -LiteralPath $textPath)) { Remove-Item -LiteralPath $textPath -Force -ErrorAction Stop }
        }
        catch { $publishError += "; summary rollback failed: $($_.Exception.Message)" }
        throw $publishError
    }
    finally {
        foreach ($path in @($jsonTemp, $textTemp, $jsonBackup, $textBackup)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}

function Complete-VmAcceptanceLifecycle {
    param(
        [AllowNull()][string]$PriorError,
        [scriptblock]$EvidenceWriter,
        [scriptblock]$FinalResumeCleanup,
        [scriptblock]$SummaryFactory,
        [scriptblock]$SummaryWriter
    )
    $errors = New-Object Collections.ArrayList
    if ($PriorError) { [void]$errors.Add($PriorError) }
    $evidenceWritten = $false
    try {
        & $EvidenceWriter
        $evidenceWritten = $true
    }
    catch { [void]$errors.Add("final evidence write failed: $($_.Exception.Message)") }
    if ($evidenceWritten) {
        try { & $FinalResumeCleanup }
        catch { [void]$errors.Add("final resume cleanup failed: $($_.Exception.Message)") }
    }
    $status = if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }
    $summary = $null
    $summaryWritten = $false
    try {
        $summary = & $SummaryFactory $status $(if ($errors.Count) { $errors -join '; ' } else { $null })
        & $SummaryWriter $summary
        $summaryWritten = $true
    }
    catch {
        [void]$errors.Add("summary write failed: $($_.Exception.Message)")
        $status = 'FAIL'
        try {
            $summary = & $SummaryFactory $status ($errors -join '; ')
            & $SummaryWriter $summary
            $summaryWritten = $true
        }
        catch { [void]$errors.Add("FAIL summary write failed: $($_.Exception.Message)") }
    }
    return [PSCustomObject]@{
        Status = $status
        ExitCode = if ($status -eq 'PASS' -and $summaryWritten) { 0 } else { 1 }
        Error = if ($errors.Count) { $errors -join '; ' } else { $null }
        Summary = $summary
        SummaryWritten = $summaryWritten
    }
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
    $ownershipPropertyNames = if ($ownershipSpec) { @($ownershipSpec.PSObject.Properties.Name) } else { @() }
    $ownershipPathKinds = if ($ownershipPropertyNames -contains 'pathKinds') { @($ownershipSpec.PSObject.Properties['pathKinds'].Value) } else { @() }
    foreach ($kind in $ownershipPathKinds) {
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
    if ($ownershipSpec -and $ownershipPropertyNames -contains 'npmPackages') {
        foreach ($value in @($ownershipSpec.PSObject.Properties['npmPackages'].Value)) { [void]$npmPackages.Add([string]$value) }
    }
    if ($ownershipSpec -and $ownershipPropertyNames -contains 'wingetPackages') {
        foreach ($value in @($ownershipSpec.PSObject.Properties['wingetPackages'].Value)) { [void]$wingetPackages.Add([string]$value) }
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

function Invoke-VmResumeControlFlow {
    param($State, [int]$ScenarioCount, [scriptblock]$PendingCleanup)
    if ([string]$State.Phase -ne 'resume-cleanup-pending') { throw "Unsupported resume phase '$($State.Phase)'" }
    $startIndex = [int]$State.NextScenarioIndex
    if ($startIndex -lt 0 -or $startIndex -gt $ScenarioCount) { throw "Resume scenario index $startIndex is outside 0..$ScenarioCount" }
    $cleanupResult = & $PendingCleanup
    if (-not $cleanupResult -or -not [bool]$cleanupResult.Success) { throw 'Pending resume cleanup did not complete successfully' }
    return [PSCustomObject]@{ NextScenarioIndex = $startIndex; CleanupCompleted = $true }
}

if ($env:CCDI_ACCEPTANCE_IMPORT_ONLY -eq '1') { return }

if ($Mode -eq 'TestSafe' -and -not $PSBoundParameters.ContainsKey('ControlRoot')) {
    $ControlRoot = Join-Path ([IO.Path]::GetTempPath()) 'CCDI-Acceptance-Control'
}

$resumeBootstrapState = if ($Resume) { Read-AcceptanceResumeState -ControlRoot $ControlRoot -ScenarioFile $scenarioFile -RequireRunArtifacts } else { $null }
if ($resumeBootstrapState) {
    $Mode = [string]$resumeBootstrapState.Mode; $Version = [string]$resumeBootstrapState.Version
    $CredentialTarget = [string]$resumeBootstrapState.CredentialTarget
    $AcknowledgeRealInstall = [bool]$resumeBootstrapState.AcknowledgeRealInstall
    $AcknowledgeRestart = $resumeBootstrapState.PSObject.Properties.Name -contains 'AcknowledgeRestart' -and [bool]$resumeBootstrapState.AcknowledgeRestart
}
$runId = if ($Resume) { [string]$resumeBootstrapState.RunId } else { Get-Date -Format "yyyyMMdd-HHmmss-fff" }
$instanceLock = Enter-AcceptanceInstanceLock -ControlRoot $ControlRoot
$processExitCode = 1
try {
$paths = Get-AcceptanceControlPaths -ControlRoot $ControlRoot -RunId $runId
foreach ($directory in @($paths.Root, $paths.Baseline, $paths.Runs, $paths.Run)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$scenarioRoot = Join-Path $paths.Run "scenarios"
$snapshotTemp = Join-Path $paths.Run "snapshot-temp"
New-Item -ItemType Directory -Path $scenarioRoot, $snapshotTemp -Force | Out-Null

$releaseOutputRoot = if ($Mode -eq 'TestSafe') { Join-Path $paths.Run 'release-output' } else { Join-Path $ProjectRoot 'release' }
$zipPath = Join-Path $releaseOutputRoot "ClaudeCode-DeepSeek-本地配置助手-v$Version.zip"

$settingsBytes = $null
$baseline = $null
$nextScenarioIndex = 0
$phase = "preflight"
$allResults = New-Object System.Collections.ArrayList
$cleanupReports = New-Object System.Collections.ArrayList
$stageResults = New-Object System.Collections.ArrayList
$finalStatus = "FAIL"
$errorMessage = $null
$protectedPids = @()
$pendingOwnership = New-AcceptanceOwnership
$currentScenarioOwnership = New-AcceptanceOwnership
$staticGuardBefore = $null
$staticGuardActive = $false

try {
    Assert-VmLiveGate -ZipPath $zipPath
    $protectedPids = Get-ProtectedProcessIds
    if ($Resume) {
        $resumeState = $resumeBootstrapState
        $nextScenarioIndex = [int]$resumeState.NextScenarioIndex
        $phase = [string]$resumeState.Phase
        Import-AcceptanceResumeResults -State $resumeState -StageResults $stageResults -ScenarioResults $allResults -CleanupReports $cleanupReports
        if ($resumeState.PendingOwnership) { $pendingOwnership = $resumeState.PendingOwnership }
        $baseline = Get-Content -LiteralPath (Join-Path $paths.Baseline "baseline-before.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $settingsBackup = Join-Path $paths.Baseline "settings.json.bytes"
        if ($baseline.Settings.Exists) { $settingsBytes = [IO.File]::ReadAllBytes($settingsBackup) }
        [void](Remove-AcceptanceResume -Paths $paths -KeepState)
    }
    else {
        if ($Mode -eq "Live") {
            $preexistingRequiredCleanCommands = @("claude", "node", "npm") | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue }
            if ((Get-VmAcceptanceCollectionCount $preexistingRequiredCleanCommands) -gt 0) {
                throw "Live baseline must start without claude/node/npm: $($preexistingRequiredCleanCommands -join ', ')"
            }
        }
        $staticGuardBefore = Get-VmStaticGuardSnapshot
        $staticGuardActive = $true
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
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "build-release.ps1"), "-Version", $Version, '-OutputDir', $releaseOutputRoot
        ) -TimeoutSec 300 -EvidenceRoot $paths.Run))

        $staticGuardAfter = Get-VmStaticGuardSnapshot
        $staticDifferences = @(Compare-VmStaticGuardSnapshot -Before $staticGuardBefore -After $staticGuardAfter)
        if ($staticGuardAfter.SettingsBytes) { [Array]::Clear($staticGuardAfter.SettingsBytes, 0, $staticGuardAfter.SettingsBytes.Length) }
        if ($staticDifferences.Count -gt 0) {
            Restore-VmStaticGuardSnapshot -Snapshot $staticGuardBefore
            $restoredStatic = Get-VmStaticGuardSnapshot
            $restoredDifferences = @(Compare-VmStaticGuardSnapshot -Before $staticGuardBefore -After $restoredStatic)
            if ($restoredStatic.SettingsBytes) { [Array]::Clear($restoredStatic.SettingsBytes, 0, $restoredStatic.SettingsBytes.Length) }
            if ($restoredDifferences.Count -gt 0) { throw "Static validation changed machine state and rollback was incomplete: $($restoredDifferences -join ', ')" }
            $staticGuardActive = $false
            if ($staticGuardBefore.SettingsBytes) { [Array]::Clear($staticGuardBefore.SettingsBytes, 0, $staticGuardBefore.SettingsBytes.Length) }
            throw "Static validation changed guarded machine state: $($staticDifferences -join ', ')"
        }
        if ($Mode -eq 'Live') {
            $postStaticCommands = @('claude', 'node', 'npm') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue }
            if ((Get-VmAcceptanceCollectionCount $postStaticCommands) -gt 0) { throw "Static validation polluted the Live clean-install baseline: $($postStaticCommands -join ', ')" }
        }
        $staticGuardActive = $false
        if ($staticGuardBefore.SettingsBytes) { [Array]::Clear($staticGuardBefore.SettingsBytes, 0, $staticGuardBefore.SettingsBytes.Length) }

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
    if ($Resume) {
        $resumeFlow = Invoke-VmResumeControlFlow -State $resumeState -ScenarioCount $orderedScenarios.Count -PendingCleanup {
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
                    [void](Invoke-VmAuthorizedRestart -ResumeState $resume)
                    $processExitCode = 194
                    exit 194
                }
                throw "Resume cleanup failed: $($resumeCleanup.Errors -join '; ')"
            }
            $resumeAfter = Get-AcceptanceEnvironmentSnapshot -ProjectRoot $ProjectRoot -TempRoot $snapshotTemp
            $resumeEquivalent = Test-AcceptanceBaselineEquivalent -Baseline $baseline -Candidate $resumeAfter -IgnoredProcessIds $protectedPids
            if (-not $resumeEquivalent.Equivalent) { throw "Resume cleanup did not restore baseline: $($resumeEquivalent.Differences -join '; ')" }
            [void](Remove-AcceptanceResume -Paths $paths)
            return [PSCustomObject]@{ Success = $true }
        }
        $nextScenarioIndex = [int]$resumeFlow.NextScenarioIndex
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
        $currentScenarioOwnership = New-AcceptanceOwnership

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
            $currentScenarioOwnership = Get-VmScenarioOwnership -Scenario $scenario -SetupState $setupState -ScenarioMode $scenarioMode
            if ($scenarioMode -eq "Live") {
                $setupState = Start-LiveScenarioSetup -Scenario $scenario -SceneDir $sceneDir
                $currentScenarioOwnership = Get-VmScenarioOwnership -Scenario $scenario -SetupState $setupState -ScenarioMode $scenarioMode
            }
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
                [void](Invoke-VmAuthorizedRestart -ResumeState $resume)
                $processExitCode = 194
                exit 194
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

}
catch {
    $errorMessage = $_.Exception.Message
    if ($staticGuardActive -and $staticGuardBefore) {
        try {
            Restore-VmStaticGuardSnapshot -Snapshot $staticGuardBefore
            $guardAfterFailure = Get-VmStaticGuardSnapshot
            $guardFailureDifferences = @(Compare-VmStaticGuardSnapshot -Before $staticGuardBefore -After $guardAfterFailure)
            if ($guardAfterFailure.SettingsBytes) { [Array]::Clear($guardAfterFailure.SettingsBytes, 0, $guardAfterFailure.SettingsBytes.Length) }
            if ($guardFailureDifferences.Count -gt 0) { throw "guard differences remain: $($guardFailureDifferences -join ', ')" }
        }
        catch { $errorMessage += "; static guard rollback exception: $($_.Exception.Message)" }
        finally {
            $staticGuardActive = $false
            if ($staticGuardBefore.SettingsBytes) { [Array]::Clear($staticGuardBefore.SettingsBytes, 0, $staticGuardBefore.SettingsBytes.Length) }
        }
    }
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

$summaryFullSha = try { (& git -C $ProjectRoot rev-parse HEAD) } catch { $null }
$summaryZipSha = if (Test-Path -LiteralPath $zipPath) { (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash } else { $null }
$passedScenarioCount = @($allResults | Where-Object { $_.Status -eq 'PASS' }).Count
$failedScenarioCount = @($allResults | Where-Object { $_.Status -ne 'PASS' }).Count
$lifecycle = Complete-VmAcceptanceLifecycle -PriorError $errorMessage -EvidenceWriter {
    Write-JsonFile -Path (Join-Path $paths.Run 'scenario-results.json') -Value @($allResults)
    Write-JsonFile -Path (Join-Path $paths.Run 'cleanup-report.json') -Value @($cleanupReports)
} -FinalResumeCleanup {
    [void](Remove-AcceptanceResume -Paths $paths)
} -SummaryFactory {
    param([string]$Status, [AllowNull()][string]$ErrorText)
    [ordered]@{
        SchemaVersion = 1; RunId = $runId; Status = $Status; Mode = $Mode; Version = $Version
        FullSHA = $summaryFullSha
        Zip = $zipPath; ZipSHA256 = $summaryZipSha
        Phase = if ($Status -eq 'PASS') { 'complete' } else { $phase }
        StaticStages = @($stageResults); Scenarios = @($allResults)
        ScenariosPassed = $passedScenarioCount; ScenariosFailed = $failedScenarioCount
        Error = $ErrorText; CompletedAt = (Get-Date).ToString('o')
    }
} -SummaryWriter {
    param($Value)
    $textLines = @(
        'CCDI VM final acceptance', "Status: $($Value.Status)", "Mode: $Mode", "Version: $Version", "Full SHA: $($Value.FullSHA)",
        "ZIP SHA256: $($Value.ZipSHA256)", "Scenarios passed: $passedScenarioCount", "Scenarios failed: $failedScenarioCount", "Run directory: $($paths.Run)",
        $(if ($Value.Error) { "Error: $($Value.Error)" } else { $null })
    ) | Where-Object { $null -ne $_ }
    Write-VmSummaryArtifactsTransactional -RunPath $paths.Run -Summary $Value -TextLines $textLines
}
$finalStatus = [string]$lifecycle.Status
$errorMessage = [string]$lifecycle.Error
$processExitCode = [int]$lifecycle.ExitCode
if ($lifecycle.SummaryWritten) { Write-VmAcceptance "Summary: $(Join-Path $paths.Run 'summary.txt')" }
if ($finalStatus -ne 'PASS') { Write-VmAcceptance "FAIL: $errorMessage" Red }
else { Write-VmAcceptance 'PASS' Green }
}
catch {
    $processExitCode = 1
    Write-VmAcceptance "FAIL outside reportable run lifecycle: $($_.Exception.Message)" Red
}
finally {
    Exit-AcceptanceInstanceLock -Lock $instanceLock
}
exit $processExitCode
