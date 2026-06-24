[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$module = Join-Path $PSScriptRoot 'lib\AcceptanceEnvironment.ps1'
. $module
. (Join-Path $PSScriptRoot 'lib\ReleaseSafety.ps1')

$oldImport = $env:CCDI_ACCEPTANCE_IMPORT_ONLY
$env:CCDI_ACCEPTANCE_IMPORT_ONLY = '1'
try { . (Join-Path $PSScriptRoot 'vm-final-acceptance.ps1') }
finally { if ($null -eq $oldImport) { Remove-Item Env:\CCDI_ACCEPTANCE_IMPORT_ONLY -ErrorAction SilentlyContinue } else { $env:CCDI_ACCEPTANCE_IMPORT_ONLY = $oldImport } }

$testRoot = Join-Path $env:TEMP ('ccdi-vm-acceptance-test-' + [guid]::NewGuid().ToString('N'))
$oldProfile = $env:USERPROFILE; $oldAppData = $env:APPDATA; $oldLocalAppData = $env:LOCALAPPDATA
$oldTestDesktop = $env:CCDI_TEST_DESKTOP; $oldProcessPath = $env:Path
$oldUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$oldProgramFiles = $env:ProgramFiles; $oldProgramFilesX86 = ${env:ProgramFiles(x86)}
$installerEnvNames = @(
    'CCDI_TEST_MODE', 'CCDI_TEST_USERPROFILE', 'CCDI_TEST_ARTIFACT_ROOT',
    'CCDI_MOCK_INSTALL_DECISION', 'CCDI_MOCK_CLAUDE', 'CCDI_MOCK_OFFICIAL',
    'CCDI_MOCK_NATIVE_INSTALL', 'CCDI_MOCK_WINGET', 'CCDI_MOCK_NODE',
    'CCDI_MOCK_NPM', 'CCDI_MOCK_NPMMIRROR', 'CCDI_MOCK_NODE_INSTALL',
    'CCDI_MOCK_NODE_VERSION', 'CCDI_MOCK_NPM_VERSION', 'CCDI_MOCK_NPM_INSTALL',
    'CCDI_MOCK_NODE_EXE', 'CCDI_MOCK_NPM_CMD'
)
$oldInstallerEnv = @{}
foreach ($installerEnvName in $installerEnvNames) { $oldInstallerEnv[$installerEnvName] = [Environment]::GetEnvironmentVariable($installerEnvName, 'Process') }
$passes = New-Object Collections.ArrayList

function Assert-Test {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "VM acceptance functional test failed: $Name" }
    [void]$passes.Add($Name); Write-Host "[vm-test] PASS: $Name" -ForegroundColor Green
}

function New-TestSnapshot {
    param([object[]]$Files, [object[]]$Npm = @(), [object[]]$Winget = @(), [object[]]$Processes = @())
    [PSCustomObject]@{
        UserPath = [Environment]::GetEnvironmentVariable('Path', 'User'); MachinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine'); ProcessPath = $env:Path
        Settings = [PSCustomObject]@{ Path = (Join-Path $testRoot 'unused-settings.json'); Exists = $false; Length = 0; SHA256 = $null }
        Commands = @(); NpmGlobal = @($Npm); Winget = @($Winget); Registry = @(); Files = @($Files); Processes = @($Processes); Services = @(); ScheduledTasks = @()
    }
}

function New-TestResumeState {
    param(
        [string]$RunId = '20260623-120000-001',
        [ValidateSet('TestSafe', 'Live')][string]$Mode = 'Live',
        [int]$NextScenarioIndex = 1,
        [string[]]$ScenarioIds
    )
    $stageResult = [ordered]@{
        Name = 'stage-before'; ExitCode = 0; TimedOut = $false; DurationSec = 1.25
        Stdout = 'stage-before.stdout.txt'; Stderr = 'stage-before.stderr.txt'; Result = 'stage-before.result.json'
    }
    if (-not $ScenarioIds) {
        $generatedIds = New-Object Collections.ArrayList
        for ($i = 0; $i -lt $NextScenarioIndex; $i++) { [void]$generatedIds.Add("scenario-before-$i") }
        $ScenarioIds = @($generatedIds)
    }
    if ($ScenarioIds.Count -ne $NextScenarioIndex) { throw "Test fixture ScenarioIds count must match NextScenarioIndex" }
    $scenarioResults = New-Object Collections.ArrayList
    foreach ($scenarioId in @($ScenarioIds)) {
        [void]$scenarioResults.Add([ordered]@{ Id = $scenarioId; Mode = $Mode; Status = 'PASS'; Stage = $stageResult; Error = $null })
    }
    [ordered]@{
        SchemaVersion = 3; RunId = $RunId; Mode = $Mode; Version = '1.3.3'; CredentialTarget = 'TEST_TARGET'
        AcknowledgeRealInstall = ($Mode -eq 'Live'); AcknowledgeRestart = ($Mode -eq 'Live')
        Phase = 'resume-cleanup-pending'; NextScenarioIndex = $NextScenarioIndex
        StageResults = @($stageResult)
        ScenarioResults = @($scenarioResults)
        CleanupReports = @([ordered]@{
            Scenario = 'cleanup-before'; Phase = 'post'
            Report = [ordered]@{
                Success = $true; Actions = @('removed-owned-state'); Errors = @(); Reports = @('cleanup-evidence.json')
                Ownership = New-AcceptanceOwnership
            }
        })
        PendingOwnership = New-AcceptanceOwnership
        Error = $null; SavedAt = '2026-06-23T12:00:00.0000000+08:00'
    }
}

function Copy-TestResumeState {
    param($State)
    return ($State | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
}

function Write-TestResumeState {
    param($Paths, $State)
    New-Item -ItemType Directory -Path $Paths.Root -Force | Out-Null
    Write-AcceptanceJsonFileAtomic -Path $Paths.ResumeState -Value $State
}

function Invoke-TestRegistrationFault {
    param(
        [string]$Name,
        [ValidateSet('None','State','UserTask','Bootstrap','SystemTask','VerifyMissing','VerifyMismatch','Query','QueryAfterRegistration','Report','ExistingSameState','ExistingDifferentState','ExistingCorruptState')][string]$Fault = 'None',
        [switch]$RollbackFails,
        [switch]$SeedPreexistingTasks
    )
    $paths = Get-AcceptanceControlPaths -ControlRoot (Join-Path $testRoot "registration-$Name") -RunId '20260623-120000-001'
    New-Item -ItemType Directory -Path $paths.Root -Force | Out-Null
    $state = New-TestResumeState
    if ($Fault -eq 'ExistingSameState') { Write-AcceptanceJsonFileAtomic -Path $paths.ResumeState -Value $state }
    elseif ($Fault -eq 'ExistingDifferentState') { Write-AcceptanceJsonFileAtomic -Path $paths.ResumeState -Value (New-TestResumeState -RunId '20260623-120000-999') }
    elseif ($Fault -eq 'ExistingCorruptState') { [IO.File]::WriteAllText($paths.ResumeState, '{CORRUPT', [Text.Encoding]::UTF8) }
    $existingStateBytes = if (Test-Path -LiteralPath $paths.ResumeState) { [IO.File]::ReadAllBytes($paths.ResumeState) } else { $null }
    $tasks = @{}
    if ($SeedPreexistingTasks) {
        $tasks[$paths.ResumeUserTask] = [PSCustomObject]@{ Exists = $true; Execute = 'powershell.exe'; Arguments = 'PREEXISTING-USER' }
        $tasks[$paths.ResumeTask] = [PSCustomObject]@{ Exists = $true; Execute = 'powershell.exe'; Arguments = 'PREEXISTING-SYSTEM' }
    }
    $events = New-Object Collections.ArrayList
    $counters = @{ Probe = 0 }
    $stateWriter = {
        param($Path, $Value)
        [void]$events.Add('write-state')
        if ($Fault -eq 'State') { throw 'INJECTED state write failure' }
        Write-AcceptanceJsonFileAtomic -Path $Path -Value $Value
    }
    $userRegistrar = {
        param($Spec)
        [void]$events.Add('register-user')
        if ($Fault -eq 'UserTask') { throw 'INJECTED user task registration failure' }
        $tasks[$Spec.UserTaskName] = [PSCustomObject]@{ Exists = $true; Execute = 'powershell.exe'; Arguments = $Spec.Arguments }
    }
    $bootstrapWriter = {
        param($Path, $Text)
        [void]$events.Add('write-bootstrap')
        if ($Fault -eq 'Bootstrap') { throw 'INJECTED bootstrap write failure' }
        [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
    }
    $systemRegistrar = {
        param($Spec)
        [void]$events.Add('register-system')
        if ($Fault -eq 'SystemTask') { throw 'INJECTED SYSTEM task registration failure' }
        if ($Fault -ne 'VerifyMissing') {
            $arguments = if ($Fault -eq 'VerifyMismatch') { 'WRONG-ARGUMENTS' } else { $Spec.SystemArguments }
            $tasks[$Spec.SystemTaskName] = [PSCustomObject]@{ Exists = $true; Execute = 'powershell.exe'; Arguments = $arguments }
        }
    }
    $taskProbe = {
        param($TaskName)
        $counters.Probe++
        [void]$events.Add("probe-$TaskName")
        if ($Fault -eq 'Query' -or ($Fault -eq 'QueryAfterRegistration' -and $counters.Probe -gt 2)) { throw 'INJECTED task query RPC failure' }
        if ($tasks.ContainsKey($TaskName)) { return $tasks[$TaskName] }
        return [PSCustomObject]@{ Exists = $false; Execute = $null; Arguments = $null }
    }
    $taskDelete = {
        param($TaskName)
        [void]$events.Add("delete-$TaskName")
        if ($RollbackFails) { throw 'INJECTED rollback delete failure' }
        [void]$tasks.Remove($TaskName)
    }
    $reportWriter = {
        param($Path, $Value)
        [void]$events.Add('write-registration-report')
        if ($Fault -eq 'Report') { throw 'INJECTED registration report write failure' }
        Write-AcceptanceJsonFileAtomic -Path $Path -Value $Value
    }
    $errorText = $null
    try {
        [void](Register-AcceptanceResume -Paths $paths -EntryScript (Join-Path $PSScriptRoot 'vm-final-acceptance.ps1') -State $state -ScenarioCount 7 `
            -StateWriter $stateWriter -UserTaskRegistrar $userRegistrar -BootstrapWriter $bootstrapWriter -SystemTaskRegistrar $systemRegistrar `
            -TaskProbe $taskProbe -TaskDeleteInvoker $taskDelete -ReportWriter $reportWriter)
    }
    catch { $errorText = $_.Exception.Message }
    $report = if (Test-Path -LiteralPath $paths.ResumeRegistrationReport) {
        Get-Content -LiteralPath $paths.ResumeRegistrationReport -Raw -Encoding UTF8 | ConvertFrom-Json
    } else { $null }
    [PSCustomObject]@{ Paths = $paths; Tasks = $tasks; Events = @($events); Error = $errorText; Report = $report; ExistingStateBytes = $existingStateBytes }
}

function Invoke-TestRemovalFault {
    param(
        [string]$Name,
        [ValidateSet('None','Query','Timeout','NonZero','TaskStillExists','StateDelete','StateStillExists','BootstrapDelete','BootstrapStillExists','Report')][string]$Fault = 'None',
        [switch]$KeepState
    )
    $paths = Get-AcceptanceControlPaths -ControlRoot (Join-Path $testRoot "removal-$Name") -RunId '20260623-120000-001'
    New-Item -ItemType Directory -Path $paths.Root -Force | Out-Null
    [IO.File]::WriteAllText($paths.ResumeState, 'STATE-MUST-SURVIVE-FAILURE', [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($paths.ResumeBootstrap, 'BOOTSTRAP', [Text.Encoding]::UTF8)
    $tasks = @{ $paths.ResumeTask = $true; $paths.ResumeUserTask = $true }
    $events = New-Object Collections.ArrayList
    $probe = {
        param($TaskName)
        [void]$events.Add("probe-$TaskName")
        if ($Fault -eq 'Query') { throw 'INJECTED task query RPC failure' }
        return $tasks.ContainsKey($TaskName)
    }
    $delete = {
        param($FilePath, $Arguments)
        $taskName = [string]$Arguments[2]
        [void]$events.Add("delete-$taskName")
        if ($Fault -eq 'Timeout') { return [PSCustomObject]@{ TimedOut = $true; ExitCode = $null; StdOut = ''; StdErr = '' } }
        if ($Fault -eq 'NonZero') { return [PSCustomObject]@{ TimedOut = $false; ExitCode = 5; StdOut = ''; StdErr = 'ACCESS DENIED' } }
        if ($Fault -ne 'TaskStillExists') { [void]$tasks.Remove($taskName) }
        return [PSCustomObject]@{ TimedOut = $false; ExitCode = 0; StdOut = ''; StdErr = '' }
    }
    $fileRemove = {
        param($Path)
        [void]$events.Add("remove-file-$([IO.Path]::GetFileName($Path))")
        if (($Fault -eq 'StateDelete' -and $Path -eq $paths.ResumeState) -or ($Fault -eq 'BootstrapDelete' -and $Path -eq $paths.ResumeBootstrap)) {
            throw "INJECTED file deletion failure: $Path"
        }
        if (($Fault -eq 'StateStillExists' -and $Path -eq $paths.ResumeState) -or ($Fault -eq 'BootstrapStillExists' -and $Path -eq $paths.ResumeBootstrap)) { return }
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    $reportWriter = {
        param($Path, $Value)
        [void]$events.Add('write-cleanup-report')
        if ($Fault -eq 'Report') { throw 'INJECTED cleanup report write failure' }
        Write-AcceptanceJsonFileAtomic -Path $Path -Value $Value
    }
    $errorText = $null; $result = $null
    try {
        $result = Remove-AcceptanceResume -Paths $paths -KeepState:$KeepState -TaskCommandInvoker $delete -TaskExistenceProbe $probe `
            -FileRemoveInvoker $fileRemove -ReportWriter $reportWriter
    }
    catch { $errorText = $_.Exception.Message }
    $report = if (Test-Path -LiteralPath $paths.ResumeCleanupReport) {
        Get-Content -LiteralPath $paths.ResumeCleanupReport -Raw -Encoding UTF8 | ConvertFrom-Json
    } else { $null }
    [PSCustomObject]@{ Paths = $paths; Tasks = $tasks; Events = @($events); Error = $errorText; Result = $result; Report = $report }
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

# Capture the real environment before any test runs. Every assertion below must leave
# these byte-identical: no real User/Machine/Process PATH drift and no real settings.json drift.
$realSettingsPath = Join-Path $oldProfile '.claude\settings.json'
$realEnvBaseline = [ordered]@{
    UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    MachinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    ProcessPath = $env:Path
    SettingsExists = Test-Path -LiteralPath $realSettingsPath
    SettingsLength = if (Test-Path -LiteralPath $realSettingsPath) { (Get-Item -LiteralPath $realSettingsPath -Force).Length } else { 0 }
    SettingsHash = if (Test-Path -LiteralPath $realSettingsPath) { (Get-FileHash -LiteralPath $realSettingsPath -Algorithm SHA256).Hash } else { $null }
}

try {
    # Single-instance refusal occurs before any cleanup-capable work.
    $control = Join-Path $testRoot 'mutex-control'
    $lock1 = Enter-AcceptanceInstanceLock -ControlRoot $control
    $secondRejected = $false
    try { $lock2 = Enter-AcceptanceInstanceLock -ControlRoot $control } catch { $secondRejected = $true }
    Assert-Test $secondRejected 'single instance rejects second owner'
    Exit-AcceptanceInstanceLock $lock1

    # Created, modified, and removed paths are restored from captured bytes.
    $owned = Join-Path $testRoot 'owned-files'; $backup = Join-Path $testRoot 'baseline-bytes'
    New-Item -ItemType Directory -Path (Join-Path $owned 'removed-dir') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $owned 'modified.txt'), 'ORIGINAL-MODIFIED', [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $owned 'removed.txt'), 'ORIGINAL-REMOVED', [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText((Join-Path $owned 'removed-dir\nested.txt'), 'ORIGINAL-NESTED', [Text.Encoding]::UTF8)
    $beforeFiles = Get-AcceptanceFileState -Roots @($owned) -CaptureBytes -BackupRoot $backup
    $before = New-TestSnapshot $beforeFiles
    [IO.File]::WriteAllText((Join-Path $owned 'modified.txt'), 'CHANGED', [Text.Encoding]::UTF8)
    Remove-Item -LiteralPath (Join-Path $owned 'removed.txt') -Force
    Remove-Item -LiteralPath (Join-Path $owned 'removed-dir') -Recurse -Force
    [IO.File]::WriteAllText((Join-Path $owned 'created.txt'), 'CREATED', [Text.Encoding]::UTF8)
    $after = New-TestSnapshot (Get-AcceptanceFileState -Roots @($owned))
    $delta = Compare-AcceptanceSnapshot $before $after
    $ownership = New-AcceptanceOwnership -PathRoots @($owned)
    $reset = Reset-AcceptanceEnvironment -Baseline $before -Current $after -Delta $delta -ProjectRoot $ProjectRoot -ControlRoot (Join-Path $testRoot 'control-a') -ResultRoot (Join-Path $testRoot 'results-a') -AllowedCleanupRoots @($owned) -ProtectedProcessIds @($PID) -Ownership $ownership
    Assert-Test $reset.Success 'created modified removed rollback succeeds'
    Assert-Test (([IO.File]::ReadAllText((Join-Path $owned 'modified.txt')) -eq 'ORIGINAL-MODIFIED') -and ([IO.File]::ReadAllText((Join-Path $owned 'removed.txt')) -eq 'ORIGINAL-REMOVED') -and ([IO.File]::ReadAllText((Join-Path $owned 'removed-dir\nested.txt')) -eq 'ORIGINAL-NESTED') -and -not (Test-Path (Join-Path $owned 'created.txt'))) 'rollback restores exact file bytes'

    # An existing .claude baseline tracks scenario-created files while preserving the
    # exact _git_cache.json exclusion and the pre-existing settings.json bytes.
    $existingClaudeRoot = Join-Path $testRoot 'profile-existing\.claude'
    $existingSettings = Join-Path $existingClaudeRoot 'settings.json'
    $ignoredGitCache = Join-Path $existingClaudeRoot '_git_cache.json'
    $scenarioNewState = Join-Path $existingClaudeRoot 'new-state'
    New-Item -ItemType Directory -Path $existingClaudeRoot -Force | Out-Null
    [IO.File]::WriteAllText($existingSettings, 'BASELINE-SETTINGS', [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($ignoredGitCache, 'BASELINE-GIT-CACHE', [Text.Encoding]::UTF8)
    $existingClaudeBefore = New-TestSnapshot (Get-AcceptanceFileState -Roots @($existingClaudeRoot) -CaptureBytes -BackupRoot (Join-Path $testRoot 'existing-claude-baseline'))
    [IO.File]::WriteAllText($scenarioNewState, 'SCENARIO-STATE', [Text.Encoding]::UTF8)
    $existingClaudeAfter = New-TestSnapshot (Get-AcceptanceFileState -Roots @($existingClaudeRoot))
    $existingClaudeDelta = Compare-AcceptanceSnapshot $existingClaudeBefore $existingClaudeAfter
    Assert-Test (($existingClaudeBefore.Files.Path -contains $existingSettings) -and ($existingClaudeDelta.CreatedPaths -contains $scenarioNewState) -and -not ($existingClaudeBefore.Files.Path -contains $ignoredGitCache) -and -not ($existingClaudeAfter.Files.Path -contains $ignoredGitCache)) 'existing .claude baseline tracks new scenario state and precisely ignores _git_cache.json'
    $existingClaudeReset = Reset-AcceptanceEnvironment -Baseline $existingClaudeBefore -Current $existingClaudeAfter -Delta $existingClaudeDelta `
        -ProjectRoot $ProjectRoot -ControlRoot (Join-Path $testRoot 'control-existing-claude') -ResultRoot (Join-Path $testRoot 'results-existing-claude') `
        -AllowedCleanupRoots @($existingClaudeRoot) -ProtectedProcessIds @($PID) -Ownership (New-AcceptanceOwnership -PathRoots @($scenarioNewState))
    $existingClaudeFinal = New-TestSnapshot (Get-AcceptanceFileState -Roots @($existingClaudeRoot))
    $existingClaudeEquivalent = Test-AcceptanceBaselineEquivalent -Baseline $existingClaudeBefore -Candidate $existingClaudeFinal
    Assert-Test ($existingClaudeReset.Success -and -not (Test-Path -LiteralPath $scenarioNewState) -and $existingClaudeEquivalent.Equivalent -and ([IO.File]::ReadAllText($existingSettings) -eq 'BASELINE-SETTINGS') -and ([IO.File]::ReadAllText($ignoredGitCache) -eq 'BASELINE-GIT-CACHE')) 'owned .claude scenario state cleanup restores baseline equivalence without changing ignored cache or settings'

    # Desktop project variants, installer state, and .claude.json are dynamically tracked and removed.
    $fakeProfile = Join-Path $testRoot 'profile'; $fakeDesktop = Join-Path $testRoot 'desktop'
    $env:USERPROFILE = $fakeProfile; $env:APPDATA = Join-Path $fakeProfile 'AppData\Roaming'; $env:LOCALAPPDATA = Join-Path $fakeProfile 'AppData\Local'; $env:CCDI_TEST_DESKTOP = $fakeDesktop
    New-Item -ItemType Directory -Path $fakeProfile, $fakeDesktop, $env:APPDATA, $env:LOCALAPPDATA -Force | Out-Null
    $trackedBeforeRoots = @(Get-AcceptanceKnownRoots | Where-Object { $_.StartsWith($testRoot, [StringComparison]::OrdinalIgnoreCase) })
    $trackedBefore = New-TestSnapshot (Get-AcceptanceFileState -Roots $trackedBeforeRoots -CaptureBytes -BackupRoot (Join-Path $testRoot 'desktop-baseline'))
    $desktopMain = Join-Path $fakeDesktop 'ClaudeCode-Test'; $desktopBackup = Join-Path $fakeDesktop 'ClaudeCode-Test-20260622-123456'
    $stateDir = Join-Path $fakeProfile '.claude-deepseek-installer'; $claudeJson = Join-Path $fakeProfile '.claude.json'
    New-Item -ItemType Directory -Path $desktopMain, $desktopBackup, $stateDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $desktopBackup 'marker.txt') -Value 'x'; Set-Content -LiteralPath (Join-Path $stateDir 'state.json') -Value '{}'; Set-Content -LiteralPath $claudeJson -Value '{}'
    $trackedAfterRoots = @(Get-AcceptanceKnownRoots | Where-Object { $_.StartsWith($testRoot, [StringComparison]::OrdinalIgnoreCase) })
    $trackedAfter = New-TestSnapshot (Get-AcceptanceFileState -Roots $trackedAfterRoots)
    $trackedDelta = Compare-AcceptanceSnapshot $trackedBefore $trackedAfter
    $desktopPattern = '^' + [regex]::Escape(([IO.Path]::GetFullPath($fakeDesktop)).TrimEnd('\') + '\ClaudeCode-Test-')
    $trackedOwnership = New-AcceptanceOwnership -PathRoots @($desktopMain, $stateDir, $claudeJson) -PathPatterns @($desktopPattern)
    $trackedReset = Reset-AcceptanceEnvironment -Baseline $trackedBefore -Current $trackedAfter -Delta $trackedDelta -ProjectRoot $ProjectRoot -ControlRoot (Join-Path $testRoot 'control-b') -ResultRoot (Join-Path $testRoot 'results-b') -AllowedCleanupRoots @($trackedAfterRoots + $trackedBeforeRoots) -ProtectedProcessIds @($PID) -Ownership $trackedOwnership
    Assert-Test ($trackedReset.Success -and -not (Test-Path $desktopMain) -and -not (Test-Path $desktopBackup) -and -not (Test-Path $stateDir) -and -not (Test-Path $claudeJson)) 'desktop variants and state roots are tracked and cleaned'

    # Scenario ownership may specify only pathKinds. StrictMode must not require
    # optional npmPackages/wingetPackages properties, and cleanup must already
    # have scenario ownership available if the stage later fails.
    $pathKindsOnlyScenario = [PSCustomObject]@{ ownership = [PSCustomObject]@{ pathKinds = @('installer-state') } }
    $pathKindsOwnership = Get-VmScenarioOwnership -Scenario $pathKindsOnlyScenario -SetupState $null -ScenarioMode Live
    Assert-Test (($pathKindsOwnership.PathRoots -contains ([IO.Path]::GetFullPath($stateDir).TrimEnd('\'))) -and @($pathKindsOwnership.NpmPackages).Count -eq 0 -and @($pathKindsOwnership.WingetPackages).Count -eq 0) 'scenario ownership handles pathKinds-only specification under StrictMode'

    $stageFailureStateDir = Join-Path $fakeProfile '.claude-deepseek-installer'
    $stageFailureBefore = New-TestSnapshot (Get-AcceptanceFileState -Roots @($stageFailureStateDir) -CaptureBytes -BackupRoot (Join-Path $testRoot 'stage-failure-baseline'))
    New-Item -ItemType Directory -Path $stageFailureStateDir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $stageFailureStateDir 'state.json'), '{"phase":"stage-failed"}', [Text.Encoding]::UTF8)
    $stageFailureAfter = New-TestSnapshot (Get-AcceptanceFileState -Roots @($stageFailureStateDir))
    $stageFailureDelta = Compare-AcceptanceSnapshot $stageFailureBefore $stageFailureAfter
    $stageFailureOwnership = Get-VmScenarioOwnership -Scenario $pathKindsOnlyScenario -SetupState $null -ScenarioMode Live
    $stageFailureReset = Reset-AcceptanceEnvironment -Baseline $stageFailureBefore -Current $stageFailureAfter -Delta $stageFailureDelta `
        -ProjectRoot $ProjectRoot -ControlRoot (Join-Path $testRoot 'control-stage-failure') -ResultRoot (Join-Path $testRoot 'results-stage-failure') `
        -AllowedCleanupRoots @($stageFailureStateDir) -ProtectedProcessIds @($PID) -Ownership $stageFailureOwnership
    Assert-Test ($stageFailureReset.Success -and -not (@($stageFailureReset.Reports) -match 'UNOWNED_PATH') -and -not (Test-Path -LiteralPath $stageFailureStateDir)) 'stage failure cleanup uses precomputed scenario ownership for installer state'

    # Unregistered package changes are reported without invoking an uninstall.
    $packageBefore = New-TestSnapshot @()
    $packageAfter = New-TestSnapshot @() @([PSCustomObject]@{ Id = 'unregistered-package'; Version = '1.0.0' })
    $packageDelta = Compare-AcceptanceSnapshot $packageBefore $packageAfter
    $packageReset = Reset-AcceptanceEnvironment -Baseline $packageBefore -Current $packageAfter -Delta $packageDelta -ProjectRoot $ProjectRoot -ControlRoot (Join-Path $testRoot 'control-c') -ResultRoot (Join-Path $testRoot 'results-c') -AllowedCleanupRoots @($owned) -ProtectedProcessIds @($PID) -Ownership (New-AcceptanceOwnership)
    Assert-Test ($packageReset.Success -and (@($packageReset.Reports) -match 'UNOWNED_NPM_PACKAGE') -and -not (@($packageReset.Actions) -match 'Uninstalled npm')) 'unregistered package is reported and not uninstalled'

    # An unregistered residual process is a blocking cleanup error and baseline difference.
    $processBefore = New-TestSnapshot -Files @()
    $processAfter = New-TestSnapshot -Files @() -Processes @([PSCustomObject]@{ ProcessId = 424242; Name = 'claude.exe'; CommandLine = 'test residual' })
    $processDelta = Compare-AcceptanceSnapshot $processBefore $processAfter
    $processReset = Reset-AcceptanceEnvironment -Baseline $processBefore -Current $processAfter -Delta $processDelta -ProjectRoot $ProjectRoot -ControlRoot (Join-Path $testRoot 'control-process') -ResultRoot (Join-Path $testRoot 'results-process') -AllowedCleanupRoots @($owned) -ProtectedProcessIds @($PID) -Ownership (New-AcceptanceOwnership)
    $processEquivalent = Test-AcceptanceBaselineEquivalent -Baseline $processBefore -Candidate $processAfter
    Assert-Test (-not $processReset.Success -and (@($processReset.Errors) -match 'UNOWNED_PROCESS') -and -not $processEquivalent.Equivalent) 'unregistered residual process blocks cleanup and equivalence'

    # Fault PATH is fully sandboxed: a fake npm.cmd and an in-memory PATH adapter ensure
    # no real User/Machine/Process PATH, real USERPROFILE, or real software is touched.
    # The fake USERPROFILE from the previous test stays in effect so nothing real is read.
    $sandboxPath = @{
        Process = $oldProcessPath
        User = $oldUserPath
        Machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    }
    $fakeNpmDir = Join-Path $testRoot 'fake-npm'; New-Item -ItemType Directory -Path $fakeNpmDir -Force | Out-Null
    $fakeNpm = Join-Path $fakeNpmDir 'npm.cmd'
    "@echo off`r`nexit /b 0" | Set-Content -LiteralPath $fakeNpm -Encoding ASCII
    $sandboxAdapter = New-VmSandboxPathAdapter -State $sandboxPath -NpmSource $fakeNpm
    $faultScenario = [PSCustomObject]@{ setup = [PSCustomObject]@{ installCommandFailsButClaudeAppears = $true } }
    $faultScene = Join-Path $testRoot 'fault-scene'
    New-Item -ItemType Directory -Path $faultScene -Force | Out-Null
    $faultState = Start-LiveScenarioSetup -Scenario $faultScenario -SceneDir $faultScene -PathAdapter $sandboxAdapter
    $faultBin = [string]$faultState.FaultBin
    $sandboxProc = Get-VmAdapterPath -Adapter $sandboxAdapter -Layer Process
    $sandboxUser = Get-VmAdapterPath -Adapter $sandboxAdapter -Layer User
    Assert-Test ($sandboxProc.StartsWith($faultBin, [StringComparison]::OrdinalIgnoreCase)) 'fault scenario prepends controlled process PATH in sandbox'
    Assert-Test ($sandboxUser.StartsWith($faultBin, [StringComparison]::OrdinalIgnoreCase)) 'fault scenario prepends controlled user PATH in sandbox'
    Assert-Test ($env:Path -ceq $oldProcessPath) 'real process PATH unchanged during fault setup'
    Assert-Test ([Environment]::GetEnvironmentVariable('Path', 'User') -ceq $oldUserPath) 'real user PATH unchanged during fault setup'
    Stop-LiveScenarioSetup -State $faultState
    Assert-Test ((Get-VmAdapterPath -Adapter $sandboxAdapter -Layer Process) -ceq $oldProcessPath) 'sandbox process PATH restored after stop'
    Assert-Test ((Get-VmAdapterPath -Adapter $sandboxAdapter -Layer User) -ceq $oldUserPath) 'sandbox user PATH restored after stop'
    Assert-Test (-not (Test-Path -LiteralPath $faultBin)) 'fault-bin removed after stop'
    Assert-Test (($env:Path -ceq $oldProcessPath) -and ([Environment]::GetEnvironmentVariable('Path', 'User') -ceq $oldUserPath)) 'real PATH fully unchanged across fault test'

    function Get-TestCollapsedCommandMatches {
        param([string[]]$Available)
        return @('claude', 'node', 'npm') | Where-Object { $_ -in $Available }
    }
    $preexistingZero = Get-TestCollapsedCommandMatches -Available @()
    $preexistingOne = Get-TestCollapsedCommandMatches -Available @('node')
    $preexistingMany = Get-TestCollapsedCommandMatches -Available @('claude', 'npm')
    Assert-Test ((Get-VmAcceptanceCollectionCount $preexistingZero) -eq 0) 'preexisting clean command count handles 0 under StrictMode'
    Assert-Test ((Get-VmAcceptanceCollectionCount $preexistingOne) -eq 1) 'preexisting clean command count handles 1 under StrictMode'
    Assert-Test ((Get-VmAcceptanceCollectionCount $preexistingMany) -eq 2) 'preexisting clean command count handles many under StrictMode'
    $postStaticZero = Get-TestCollapsedCommandMatches -Available @()
    $postStaticOne = Get-TestCollapsedCommandMatches -Available @('claude')
    $postStaticMany = Get-TestCollapsedCommandMatches -Available @('node', 'npm')
    Assert-Test ((Get-VmAcceptanceCollectionCount $postStaticZero) -eq 0) 'post static command count handles 0 under StrictMode'
    Assert-Test ((Get-VmAcceptanceCollectionCount $postStaticOne) -eq 1) 'post static command count handles 1 under StrictMode'
    Assert-Test ((Get-VmAcceptanceCollectionCount $postStaticMany) -eq 2) 'post static command count handles many under StrictMode'

    # Installer restart-elimination checks are fully sandboxed and mock-driven:
    # no winget/npm/Claude command is executed, and no real profile/PATH is changed.
    $installerSaved = @{
        UserProfile = $env:USERPROFILE
        AppData = $env:APPDATA
        LocalAppData = $env:LOCALAPPDATA
        ProcessPath = $env:Path
        ProgramFiles = $env:ProgramFiles
        ProgramFilesX86 = ${env:ProgramFiles(x86)}
    }
    try {
        foreach ($installerEnvName in $installerEnvNames) { Remove-Item -Path "Env:\$installerEnvName" -ErrorAction SilentlyContinue }
        $installerRoot = Join-Path $testRoot 'installer-sandbox'
        $installerProfile = Join-Path $installerRoot 'profile'
        $installerAppData = Join-Path $installerProfile 'AppData\Roaming'
        $installerLocalAppData = Join-Path $installerProfile 'AppData\Local'
        $installerProgramFiles = Join-Path $installerRoot 'ProgramFiles'
        $installerProgramFilesX86 = Join-Path $installerRoot 'ProgramFilesX86'
        $installerArtifacts = Join-Path $installerRoot 'artifacts'
        foreach ($dir in @($installerProfile, $installerAppData, $installerLocalAppData, $installerProgramFiles, $installerProgramFilesX86, $installerArtifacts)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $env:CCDI_TEST_MODE = '1'
        $env:CCDI_TEST_USERPROFILE = $installerProfile
        $env:CCDI_TEST_ARTIFACT_ROOT = $installerArtifacts
        $env:USERPROFILE = $installerProfile
        $env:APPDATA = $installerAppData
        $env:LOCALAPPDATA = $installerLocalAppData
        $env:ProgramFiles = $installerProgramFiles
        ${env:ProgramFiles(x86)} = $installerProgramFilesX86
        $env:Path = $oldProcessPath

        if (-not (Get-Command Resolve-NodeExePath -ErrorAction SilentlyContinue)) {
            . (Join-Path $ProjectRoot 'lib\bootstrap.ps1')
            $null = Initialize-CcdiScript -ScriptName 'test-vm-acceptance-installer'
        }

        $simulateReleaseSource = Get-Content -LiteralPath (Join-Path $ProjectRoot 'scripts\simulate-user-release.ps1') -Raw -Encoding UTF8
        $scenarioCSource = if ($simulateReleaseSource -match '(?s)# --- Scenario C:.*?# --- Scenario D:') { $matches[0] } else { '' }
        Assert-Test (-not [string]::IsNullOrWhiteSpace($scenarioCSource)) 'simulate-user-release Scenario C source block exists'
        Assert-Test ($scenarioCSource -notmatch 'node\.cmd' -and $scenarioCSource -match '"node\.exe"' -and $scenarioCSource -match 'CCDI_MOCK_NODE_EXE' -and $scenarioCSource -match 'CCDI_MOCK_NPM_CMD') 'Scenario C uses node.exe fixed-path mock and never node.cmd for Node'

        $scenarioCMockDir = Join-Path $installerRoot 'scenario-c-node-mock'
        New-Item -ItemType Directory -Path $scenarioCMockDir -Force | Out-Null
        $scenarioCNodeExe = Join-Path $scenarioCMockDir 'node.exe'
        $scenarioCNpmCmd = Join-Path $scenarioCMockDir 'npm.cmd'
        New-Item -ItemType File -Path $scenarioCNodeExe -Force | Out-Null
        "@echo off`r`necho 10.2.4`r`nexit /b 0`r`n" | Set-Content -LiteralPath $scenarioCNpmCmd -Encoding ASCII
        $savedScenarioCMocks = @{
            NodeExe = $env:CCDI_MOCK_NODE_EXE
            NpmCmd = $env:CCDI_MOCK_NPM_CMD
            NodeVersion = $env:CCDI_MOCK_NODE_VERSION
            NpmVersion = $env:CCDI_MOCK_NPM_VERSION
        }
        try {
            $env:CCDI_MOCK_NODE_EXE = $scenarioCNodeExe
            $env:CCDI_MOCK_NPM_CMD = $scenarioCNpmCmd
            $env:CCDI_MOCK_NODE_VERSION = 'v20.11.0'
            $env:CCDI_MOCK_NPM_VERSION = '10.2.4'
            $scenarioCNodeInfo = Test-NodeJsInstalled
            $scenarioCNpmInfo = Test-NpmInstalled
            Assert-Test ($scenarioCNodeInfo.Installed -and $scenarioCNodeInfo.IsSupported -and $scenarioCNodeInfo.Path -eq $scenarioCNodeExe -and $scenarioCNodeInfo.Source -eq 'mock_fixed_path') 'Test-NodeJsInstalled detects Scenario C mock node.exe fixed path'
            Assert-Test ($scenarioCNpmInfo.Installed -and $scenarioCNpmInfo.Path -eq $scenarioCNpmCmd -and $scenarioCNpmInfo.Source -eq 'mock_fixed_path') 'Test-NpmInstalled detects Scenario C mock npm.cmd fixed path'
        }
        finally {
            if ($null -eq $savedScenarioCMocks.NodeExe) { Remove-Item Env:\CCDI_MOCK_NODE_EXE -ErrorAction SilentlyContinue } else { $env:CCDI_MOCK_NODE_EXE = $savedScenarioCMocks.NodeExe }
            if ($null -eq $savedScenarioCMocks.NpmCmd) { Remove-Item Env:\CCDI_MOCK_NPM_CMD -ErrorAction SilentlyContinue } else { $env:CCDI_MOCK_NPM_CMD = $savedScenarioCMocks.NpmCmd }
            if ($null -eq $savedScenarioCMocks.NodeVersion) { Remove-Item Env:\CCDI_MOCK_NODE_VERSION -ErrorAction SilentlyContinue } else { $env:CCDI_MOCK_NODE_VERSION = $savedScenarioCMocks.NodeVersion }
            if ($null -eq $savedScenarioCMocks.NpmVersion) { Remove-Item Env:\CCDI_MOCK_NPM_VERSION -ErrorAction SilentlyContinue } else { $env:CCDI_MOCK_NPM_VERSION = $savedScenarioCMocks.NpmVersion }
        }

        function Invoke-RepairDepsFunctionalCase {
            param(
                [string]$Name,
                [hashtable]$Overrides,
                [switch]$AllowInstall
            )
            $caseRoot = Join-Path $installerRoot "repair-$Name"
            $caseProfile = Join-Path $caseRoot 'profile'
            $caseAppData = Join-Path $caseProfile 'AppData\Roaming'
            $caseLocalAppData = Join-Path $caseProfile 'AppData\Local'
            $caseArtifacts = Join-Path $caseRoot 'artifacts'
            foreach ($caseDir in @($caseProfile, $caseAppData, $caseLocalAppData, $caseArtifacts)) {
                New-Item -ItemType Directory -Path $caseDir -Force | Out-Null
            }
            $caseEnvNames = @(
                'CCDI_TEST_MODE', 'CCDI_TEST_USERPROFILE', 'CCDI_TEST_ARTIFACT_ROOT',
                'CCDI_MOCK_INSTALL_DECISION', 'CCDI_MOCK_CLAUDE', 'CCDI_MOCK_OFFICIAL',
                'CCDI_MOCK_NATIVE_INSTALL', 'CCDI_MOCK_WINGET', 'CCDI_MOCK_NODE',
                'CCDI_MOCK_NPM', 'CCDI_MOCK_NPMMIRROR', 'CCDI_MOCK_NODE_INSTALL',
                'CCDI_MOCK_NODE_VERSION', 'CCDI_MOCK_NPM_VERSION', 'CCDI_MOCK_NPM_INSTALL',
                'CCDI_MOCK_NODE_EXE', 'CCDI_MOCK_NPM_CMD',
                'CCDI_MOCK_USER_PATH_NATIVE', 'CCDI_MOCK_PATH_WRITE'
            )
            $savedCaseEnv = @{}
            foreach ($caseEnvName in $caseEnvNames) { $savedCaseEnv[$caseEnvName] = [Environment]::GetEnvironmentVariable($caseEnvName, 'Process') }
            $savedCaseProfile = $env:USERPROFILE
            $savedCaseAppData = $env:APPDATA
            $savedCaseLocalAppData = $env:LOCALAPPDATA
            try {
                foreach ($caseEnvName in $caseEnvNames) { Remove-Item -Path "Env:\$caseEnvName" -ErrorAction SilentlyContinue }
                $env:USERPROFILE = $caseProfile
                $env:APPDATA = $caseAppData
                $env:LOCALAPPDATA = $caseLocalAppData
                $env:CCDI_TEST_MODE = '1'
                $env:CCDI_TEST_USERPROFILE = $caseProfile
                $env:CCDI_TEST_ARTIFACT_ROOT = $caseArtifacts
                $env:CCDI_MOCK_INSTALL_DECISION = '1'
                foreach ($overrideKey in $Overrides.Keys) {
                    [Environment]::SetEnvironmentVariable([string]$overrideKey, [string]$Overrides[$overrideKey], 'Process')
                }
                $args = @('-TestSafe', '-NonInteractive', '-NoFinalPause')
                if ($AllowInstall) { $args += '-AllowInstall' }
                $run = Invoke-AcceptanceCapturedCommand -FilePath (Join-Path $ProjectRoot 'repair-deps.ps1') -ArgumentList $args -TimeoutSec 45
                $report = Get-ChildItem -LiteralPath (Join-Path $caseArtifacts 'reports') -Filter 'repair-deps-report-*.txt' -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                $reportText = if ($report) { Get-Content -LiteralPath $report.FullName -Raw -Encoding UTF8 } else { '' }
                [PSCustomObject]@{
                    Run = $run
                    Output = "$($run.StdOut)`n$($run.StdErr)"
                    ReportText = $reportText
                    ReportPath = if ($report) { $report.FullName } else { $null }
                }
            }
            finally {
                $env:USERPROFILE = $savedCaseProfile
                $env:APPDATA = $savedCaseAppData
                $env:LOCALAPPDATA = $savedCaseLocalAppData
                foreach ($caseEnvName in $caseEnvNames) {
                    $savedValue = $savedCaseEnv[$caseEnvName]
                    if ($null -eq $savedValue) { Remove-Item -Path "Env:\$caseEnvName" -ErrorAction SilentlyContinue }
                    else { [Environment]::SetEnvironmentVariable($caseEnvName, $savedValue, 'Process') }
                }
            }
        }

        $repairClaudeOk = Invoke-RepairDepsFunctionalCase -Name 'claude-ok-node-missing' -Overrides @{
            CCDI_MOCK_CLAUDE = 'ok'; CCDI_MOCK_NODE = 'missing'; CCDI_MOCK_NPM = 'missing'
        }
        $repairClaudeOkText = "$($repairClaudeOk.Output)`n$($repairClaudeOk.ReportText)"
        Assert-Test (-not $repairClaudeOk.Run.TimedOut -and $repairClaudeOk.Run.ExitCode -eq 0 -and $repairClaudeOk.ReportText -match 'Claude Code:' -and $repairClaudeOk.ReportText -match 'Node\.js/npm' -and $repairClaudeOk.ReportText -match 'npm fallback') 'repair-deps reports no repair needed when Claude is usable and Node/npm are missing'
        Assert-Test ($repairClaudeOkText -notmatch '\[(WARN|ERROR)\]\s+Node\.js' -and $repairClaudeOkText -notmatch '\[(WARN|ERROR)\]\s+npm' -and $repairClaudeOkText -notmatch 'Node\.js LTS|failed_missing_node_or_npm') 'repair-deps does not warn about optional Node/npm when Claude is usable'

        $repairNativeFirst = Invoke-RepairDepsFunctionalCase -Name 'native-before-node' -AllowInstall -Overrides @{
            CCDI_MOCK_CLAUDE = 'missing'; CCDI_MOCK_NODE = 'missing'; CCDI_MOCK_NPM = 'missing'; CCDI_MOCK_OFFICIAL = 'reachable'; CCDI_MOCK_NATIVE_INSTALL = 'success'
        }
        $repairNativeText = "$($repairNativeFirst.Output)`n$($repairNativeFirst.ReportText)"
        Assert-Test (-not $repairNativeFirst.Run.TimedOut -and $repairNativeFirst.Run.ExitCode -eq 0 -and $repairNativeText -match 'official_native' -and $repairNativeFirst.ReportText -match 'Claude Code:') 'repair-deps tries official Native before requiring Node/npm when Claude is missing'
        Assert-Test ($repairNativeText -notmatch '\[ERROR\] Claude Code repair' -and $repairNativeText -notmatch 'failed_missing_node_or_npm') 'repair-deps Native path is not pre-blocked by missing Node/npm'

        $repairFallbackNeedsNode = Invoke-RepairDepsFunctionalCase -Name 'fallback-needs-node' -AllowInstall -Overrides @{
            CCDI_MOCK_CLAUDE = 'missing'; CCDI_MOCK_NODE = 'missing'; CCDI_MOCK_NPM = 'missing'; CCDI_MOCK_OFFICIAL = 'unreachable'; CCDI_MOCK_NATIVE_INSTALL = 'fail'; CCDI_MOCK_WINGET = 'missing'
        }
        $repairFallbackText = "$($repairFallbackNeedsNode.Output)`n$($repairFallbackNeedsNode.ReportText)"
        Assert-Test (-not $repairFallbackNeedsNode.Run.TimedOut -and $repairFallbackNeedsNode.Run.ExitCode -eq 0 -and $repairFallbackText -match '\[ERROR\] Claude Code' -and $repairFallbackText -match 'Node\.js LTS|npm fallback') 'repair-deps allows Node/npm missing to become a repair blocker only when npm fallback is needed'

        # --- ACC-048: Claude native fixed-path usable + User PATH scenarios ---
        # test-vm-acceptance.ps1 is BOM-less; CJK match strings are built via [char] codes.
        $cnNoRepair = [string]::Concat([char]0x5DF2,[char]0x53EF,[char]0x7528,[char]0xFF0C,[char]0x65E0,[char]0x9700,[char]0x4FEE,[char]0x590D) # no-repair-needed CJK

        $repairNativeMissing = Invoke-RepairDepsFunctionalCase -Name 'native-path-missing' -Overrides @{
            CCDI_MOCK_CLAUDE = 'native'; CCDI_MOCK_NODE = 'missing'; CCDI_MOCK_NPM = 'missing'
        }
        $repairNativeMissingText = "$($repairNativeMissing.Output)`n$($repairNativeMissing.ReportText)"
        Assert-Test (-not $repairNativeMissing.Run.TimedOut -and $repairNativeMissing.Run.ExitCode -eq 0) 'repair-deps native fixed-path usable exits cleanly when User PATH missing'
        Assert-Test ($repairNativeMissingText -match 'source=native_local_bin') 'repair-deps judges Claude usable via native fixed path'
        Assert-Test ($repairNativeMissingText -match 'Native Install PATH' -and $repairNativeMissingText -match '\[WARN\]\s+Native Install PATH') 'repair-deps detects Native Install PATH gap when Claude fixed-path usable but User PATH missing'
        Assert-Test ($repairNativeMissingText -match '\[SKIP\]\s+Native Install PATH') 'repair-deps TestSafe skips real User PATH write for native bin'
        Assert-Test ($repairNativeMissingText -match "Claude Code $cnNoRepair") 'repair-deps reports no repair needed alongside PATH records when native usable and TestSafe skips write'
        Assert-Test ($repairNativeMissingText -notmatch '\[(WARN|ERROR)\]\s+Node\.js' -and $repairNativeMissingText -notmatch '\[(WARN|ERROR)\]\s+npm') 'repair-deps native fixed-path does not warn about optional Node/npm'
        Assert-Test ($repairNativeMissingText -notmatch 'official_native' -and $repairNativeMissingText -notmatch 'Install-ClaudeCodeAuto') 'repair-deps native usable does not trigger Claude/Node install'

        $repairNativePresent = Invoke-RepairDepsFunctionalCase -Name 'native-path-present' -Overrides @{
            CCDI_MOCK_CLAUDE = 'native'; CCDI_MOCK_NODE = 'missing'; CCDI_MOCK_NPM = 'missing'
            CCDI_MOCK_USER_PATH_NATIVE = 'present'
        }
        $repairNativePresentText = "$($repairNativePresent.Output)`n$($repairNativePresent.ReportText)"
        Assert-Test (-not $repairNativePresent.Run.TimedOut -and $repairNativePresent.Run.ExitCode -eq 0) 'repair-deps native fixed-path usable exits cleanly when User PATH present'
        Assert-Test ($repairNativePresentText -match '\[OK\]\s+Native Install PATH') 'repair-deps reports Native Install PATH OK when User PATH present'
        Assert-Test ($repairNativePresentText -match "Claude Code $cnNoRepair") 'repair-deps reports no repair needed when native usable and User PATH present'
        Assert-Test ($repairNativePresentText -notmatch '\[(WARN|ERROR)\]\s+Node\.js' -and $repairNativePresentText -notmatch '\[(WARN|ERROR)\]\s+npm') 'repair-deps native present does not warn about optional Node/npm'
        Assert-Test ($repairNativePresentText -notmatch 'official_native') 'repair-deps native present does not trigger install'

        $repairNativeWriteFail = Invoke-RepairDepsFunctionalCase -Name 'native-path-writefail' -Overrides @{
            CCDI_MOCK_CLAUDE = 'native'; CCDI_MOCK_NODE = 'missing'; CCDI_MOCK_NPM = 'missing'
            CCDI_MOCK_PATH_WRITE = 'fail'
        }
        $repairNativeWriteFailText = "$($repairNativeWriteFail.Output)`n$($repairNativeWriteFail.ReportText)"
        Assert-Test (-not $repairNativeWriteFail.Run.TimedOut -and $repairNativeWriteFail.Run.ExitCode -eq 0) 'repair-deps native fixed-path write-fail exits cleanly'
        Assert-Test ($repairNativeWriteFailText -match '\[ERROR\]\s+Native Install PATH') 'repair-deps reports PATH write failure when native bin User PATH write fails'
        Assert-Test ($repairNativeWriteFailText -notmatch "Claude Code $cnNoRepair") 'repair-deps must not claim no-repair-needed when PATH write failed'
        Assert-Test ($repairNativeWriteFailText -match '1\.\s.*\.local\\bin') 'repair-deps PATH write failure suggests manual PATH add with native bin'
        Assert-Test ($repairNativeWriteFailText -match '2\.\s.*\.cmd') 'repair-deps PATH write failure suggests running diagnostics cmd'
        Assert-Test ($repairNativeWriteFailText -notmatch '\[(WARN|ERROR)\]\s+Node\.js' -and $repairNativeWriteFailText -notmatch '\[(WARN|ERROR)\]\s+npm') 'repair-deps native write-fail does not promote Node/npm to main error'

        $repairDepsSource = Get-Content -LiteralPath (Join-Path $ProjectRoot 'repair-deps.ps1') -Raw -Encoding UTF8
        $repairCmdName = [string]::Concat([char]0x4E00, [char]0x952E, [char]0x4FEE, [char]0x590D, [char]0x4F9D, [char]0x8D56, '.cmd')
        $repairCmdSource = Get-Content -LiteralPath (Join-Path $ProjectRoot $repairCmdName) -Raw -Encoding UTF8
        $repairFinishPromptCount = @([regex]::Matches($repairCmdSource, 'Press any key to finish')).Count
        $repairHiddenFinalPauseCount = @([regex]::Matches($repairCmdSource, '(?m)^\s*pause\s*>nul\s*$')).Count
        Assert-Test ($repairDepsSource -match '\[switch\]\$NoFinalPause' -and $repairDepsSource -match 'NoFinalPause[\s\S]{0,120}Read-Host') 'repair-deps supports NoFinalPause and gates final Read-Host'
        Assert-Test ($repairCmdSource -match 'repair-deps\.ps1"\s+-NoFinalPause' -and $repairCmdSource -notmatch 'Press any key to close this window' -and $repairFinishPromptCount -eq 1 -and $repairHiddenFinalPauseCount -eq 1) 'repair-deps cmd wrapper uses NoFinalPause and one final finish pause'

        $env:CCDI_MOCK_INSTALL_DECISION = '1'
        $env:CCDI_MOCK_CLAUDE = 'missing'
        $env:CCDI_MOCK_OFFICIAL = 'unreachable'
        $env:CCDI_MOCK_WINGET = 'ok'
        $env:CCDI_MOCK_NODE = 'missing'
        $env:CCDI_MOCK_NODE_INSTALL = 'fail'
        $nodeFailure = Install-ClaudeCodeAuto
        Assert-Test ((-not $nodeFailure.Success) -and $nodeFailure.Status -eq 'node_install_failed' -and $nodeFailure.Status -ne 'node_installed_needs_restart' -and -not [string]::IsNullOrWhiteSpace($nodeFailure.UserMessage)) 'Node winget nonzero without fixed-path node/npm returns node_install_failed'

        $fakeNodeDir = Join-Path $installerProgramFiles 'nodejs'
        New-Item -ItemType Directory -Path $fakeNodeDir -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $fakeNodeDir 'node.exe') -Force | Out-Null
        "@echo off`r`necho 10.2.4`r`nexit /b 0`r`n" | Set-Content -LiteralPath (Join-Path $fakeNodeDir 'npm.cmd') -Encoding ASCII

        $env:Path = "$fakeNodeDir;$fakeNodeDir;$oldProcessPath"
        Refresh-CurrentProcessPath
        $refreshPathAfterFirst = $env:Path
        $refreshCountAfterFirst = @($env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
        for ($refreshIndex = 0; $refreshIndex -lt 20; $refreshIndex++) {
            Refresh-CurrentProcessPath
        }
        $refreshCountAfterRepeated = @($env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
        $fakeNodeEntryCount = @($env:Path -split ';' | Where-Object { $_ -eq $fakeNodeDir }).Count
        Assert-Test (($env:Path.Length -eq $refreshPathAfterFirst.Length) -and ($refreshCountAfterRepeated -eq $refreshCountAfterFirst) -and ($fakeNodeEntryCount -eq 1)) 'Refresh-CurrentProcessPath stays idempotent after repeated calls'
        $env:Path = $oldProcessPath

        $env:CCDI_MOCK_CLAUDE = 'missing'
        $env:CCDI_MOCK_OFFICIAL = 'unreachable'
        $env:CCDI_MOCK_WINGET = 'ok'
        $env:CCDI_MOCK_NODE = 'missing'
        $env:CCDI_MOCK_NODE_INSTALL = 'success'
        $env:CCDI_MOCK_NPMMIRROR = 'reachable'
        $env:CCDI_MOCK_NPM_INSTALL = 'success'
        $nodeSuccess = Install-ClaudeCodeAuto
        $processPathHasNode = @($env:Path -split ';' | Where-Object { $_ -eq $fakeNodeDir }).Count -gt 0
        Assert-Test ($nodeSuccess.Status -ne 'node_installed_needs_restart' -and $processPathHasNode) 'Node winget success injects nodejs into current PATH and continues without restart status'

        foreach ($installerEnvName in @('CCDI_MOCK_INSTALL_DECISION','CCDI_MOCK_CLAUDE','CCDI_MOCK_OFFICIAL','CCDI_MOCK_WINGET','CCDI_MOCK_NODE','CCDI_MOCK_NODE_INSTALL','CCDI_MOCK_NPMMIRROR','CCDI_MOCK_NPM_INSTALL','CCDI_MOCK_NODE_VERSION','CCDI_MOCK_NPM_VERSION')) {
            Remove-Item -Path "Env:\$installerEnvName" -ErrorAction SilentlyContinue
        }
        $emptyPathDir = Join-Path $installerRoot 'empty-path'
        New-Item -ItemType Directory -Path $emptyPathDir -Force | Out-Null
        $nativeBin = Join-Path $installerProfile '.local\bin'
        New-Item -ItemType Directory -Path $nativeBin -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $nativeBin 'claude.exe') -Force | Out-Null
        $env:Path = $emptyPathDir
        $nativeFixed = Test-ClaudeCommandExisting
        Assert-Test ($nativeFixed.Usable -and $nativeFixed.Source -eq 'native_local_bin' -and $nativeFixed.Path -like '*.local\bin\claude.exe') 'Native Claude fixed path postcheck works when Get-Command claude fails'

        Remove-Item -LiteralPath (Join-Path $nativeBin 'claude.exe') -Force
        $npmGlobalDir = Join-Path $installerAppData 'npm'
        New-Item -ItemType Directory -Path $npmGlobalDir -Force | Out-Null
        "@echo off`r`necho 2.1.0 (Claude Code)`r`nexit /b 0`r`n" | Set-Content -LiteralPath (Join-Path $npmGlobalDir 'claude.cmd') -Encoding ASCII
        "@echo 'reference only'`r`n" | Set-Content -LiteralPath (Join-Path $npmGlobalDir 'claude.ps1') -Encoding ASCII
        $env:Path = $emptyPathDir
        $npmFixed = Test-ClaudeCommandExisting
        $processPathHasNpm = @($env:Path -split ';' | Where-Object { $_ -eq $npmGlobalDir }).Count -gt 0
        Assert-Test ($npmFixed.Usable -and $npmFixed.Source -eq 'npm_global' -and $npmFixed.Path -like '*\AppData\Roaming\npm\claude.cmd' -and $processPathHasNpm) 'npm global Claude fixed path postcheck injects APPDATA npm and avoids restart'

        $startHereSource = Get-Content -LiteralPath (Join-Path $ProjectRoot 'Start-Here.ps1') -Raw -Encoding UTF8
        $startHereContinuationOk = (
            ($startHereSource -match 'Legacy restart status overridden by fixed-path postcheck') -and
            ($startHereSource -notmatch 'node_installed_needs_restart[\s\S]{0,300}Show-CompletionPage[\s\S]{0,80}return')
        )
        Assert-Test $startHereContinuationOk 'Start-Here restart statuses perform fixed-path postcheck instead of skipping configuration'

        $scenarioDoc = Get-Content -LiteralPath (Join-Path $ProjectRoot 'scripts\data\interactive-acceptance-scenarios.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $repairLauncherScenario = @($scenarioDoc.scenarioSets.TestSafe | Where-Object { $_.id -eq 'repair-launcher' })[0]
        $repairLauncherStepExpects = @($repairLauncherScenario.steps | ForEach-Object { [string]$_.expect })
        Assert-Test ([string]$repairLauncherScenario.entry -eq $repairCmdName -and $repairLauncherStepExpects -contains 'Press any key to finish') 'repair-launcher scenario waits for the real repair cmd finish prompt'

        $doctorMockScenarioIds = @(
            'doctor-mock-200', 'doctor-mock-401', 'doctor-mock-402', 'doctor-mock-429', 'doctor-mock-503',
            'doctor-mock-timeout', 'doctor-mock-dns'
        )
        $doctorMockScenarios = @($scenarioDoc.scenarioSets.TestSafe | Where-Object { $_.id -in $doctorMockScenarioIds })
        Assert-Test ($doctorMockScenarios.Count -eq $doctorMockScenarioIds.Count) 'doctor mock scenarios are all present'
        $doctorMockRoutingOk = $true
        foreach ($doctorMockScenario in $doctorMockScenarios) {
            $doctorMockArgs = if ($doctorMockScenario.PSObject.Properties.Name -contains 'entryArgs') { @($doctorMockScenario.entryArgs) } else { @() }
            $doctorMockEnvNames = if ($doctorMockScenario.PSObject.Properties.Name -contains 'environment') { @($doctorMockScenario.environment.PSObject.Properties.Name) } else { @() }
            if ([string]$doctorMockScenario.entry -ne 'doctor.ps1' -or
                [string]$doctorMockScenario.entryMode -ne 'powershell' -or
                $doctorMockArgs -notcontains '-ShareSafe' -or
                $doctorMockArgs -notcontains '-NoOpenReport' -or
                $doctorMockArgs -contains '-SkipApiTest' -or
                $doctorMockEnvNames -notcontains 'CCDI_TEST_API_STATUS') {
                $doctorMockRoutingOk = $false
            }
        }
        Assert-Test $doctorMockRoutingOk 'doctor mock scenarios run doctor.ps1 directly without SkipApiTest'
        $diagnosticLauncherScenario = @($scenarioDoc.scenarioSets.TestSafe | Where-Object { $_.id -eq 'diagnostic-launcher' })[0]
        $diagnosticRequired = @($diagnosticLauncherScenario.required)
        $diagnosticForbidden = @($diagnosticLauncherScenario.forbidden)
        $diagnosticCmdName = [string]::Concat([char]0x4E00, [char]0x952E, [char]0x8BCA, [char]0x65AD, '.cmd')
        $diagnosticCmdSource = Get-Content -LiteralPath (Join-Path $ProjectRoot $diagnosticCmdName) -Raw -Encoding ASCII
        $apiSkipText = [string]::Concat([char]0x5DF2, [char]0x6309, [char]0x53C2, [char]0x6570, [char]0x8DF3, [char]0x8FC7)
        Assert-Test ([string]$diagnosticLauncherScenario.entry -eq $diagnosticCmdName -and $diagnosticRequired -contains $apiSkipText -and $diagnosticForbidden -contains '200 OK' -and $diagnosticForbidden -contains 'HTTP 429') 'diagnostic launcher scenario still covers safe API skip behavior'
        Assert-Test ($diagnosticCmdSource -match 'doctor\.ps1"\s+-ShareSafe\s+-SkipApiTest\s+-NoOpenReport') 'diagnostic launcher keeps buyer-safe SkipApiTest arguments'

        $interactiveRunnerPath = Join-Path $ProjectRoot 'scripts\interactive-user-acceptance.ps1'
        $interactiveRunnerSource = Get-Content -LiteralPath $interactiveRunnerPath -Raw -Encoding UTF8
        $runnerTokens = $null
        $runnerErrors = $null
        $interactiveRunnerAst = [System.Management.Automation.Language.Parser]::ParseFile($interactiveRunnerPath, [ref]$runnerTokens, [ref]$runnerErrors)
        Assert-Test ($runnerErrors.Count -eq 0) 'interactive runner parses for command-builder extraction'
        $commandBuilderHelpers = @(
            'ConvertTo-WindowsCommandLineArgument',
            'Get-ScenarioEntryMode',
            'Get-ScenarioEntryArgs',
            'New-ScenarioCommandLine'
        )
        $runnerFunctionAsts = @($interactiveRunnerAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $commandBuilderHelpers -contains $node.Name
        }, $true))
        $builderTextParts = New-Object Collections.ArrayList
        foreach ($helperName in $commandBuilderHelpers) {
            $helperAst = @($runnerFunctionAsts | Where-Object { $_.Name -eq $helperName } | Select-Object -First 1)
            Assert-Test ($helperAst.Count -eq 1) "interactive runner helper exists: $helperName"
            [void]$builderTextParts.Add($helperAst[0].Extent.Text)
        }
        $builderHelperText = ($builderTextParts.ToArray() -join "`r`n")
        $builderProbe = [scriptblock]::Create($builderHelperText + @'

$powerShellScenario = [PSCustomObject]@{
    id = 'powershell-probe'
    entryMode = 'powershell'
    entryArgs = @('-ShareSafe', 'two words', 'literal & value')
}
$powerShellLine = New-ScenarioCommandLine -Scenario $powerShellScenario -EntryRelative 'doctor.ps1'
$cmdScenario = [PSCustomObject]@{ id = 'cmd-probe'; entryMode = 'cmd' }
$cmdLine = New-ScenarioCommandLine -Scenario $cmdScenario -EntryRelative 'launcher.cmd'
$newlineRejected = $false
try {
    [void](New-ScenarioCommandLine -Scenario ([PSCustomObject]@{ id = 'newline-probe'; entryMode = 'powershell'; entryArgs = @("bad`narg") }) -EntryRelative 'doctor.ps1')
}
catch { $newlineRejected = $true }
$cmdArgsRejected = $false
try {
    [void](New-ScenarioCommandLine -Scenario ([PSCustomObject]@{ id = 'cmd-args-probe'; entryMode = 'cmd'; entryArgs = @('-ignored') }) -EntryRelative 'launcher.cmd')
}
catch { $cmdArgsRejected = $true }
$nonPs1Rejected = $false
try {
    [void](New-ScenarioCommandLine -Scenario ([PSCustomObject]@{ id = 'non-ps1-probe'; entryMode = 'powershell'; entryArgs = @() }) -EntryRelative 'launcher.cmd')
}
catch { $nonPs1Rejected = $true }
[PSCustomObject]@{
    PowerShellLine = $powerShellLine
    CmdLine = $cmdLine
    NewlineRejected = $newlineRejected
    CmdArgsRejected = $cmdArgsRejected
    NonPs1Rejected = $nonPs1Rejected
}
'@)
        $builderProbeResult = & $builderProbe
        Assert-Test ($builderProbeResult.PowerShellLine -match '^powershell\.exe -NoProfile -ExecutionPolicy Bypass -File \.\\doctor\.ps1 -ShareSafe "two words" "literal & value"$' -and $builderProbeResult.PowerShellLine -notmatch '/d /s /c call') 'runner powershell entryMode builds a direct quoted command line'
        Assert-Test ($builderProbeResult.NewlineRejected -and $builderProbeResult.CmdArgsRejected -and $builderProbeResult.NonPs1Rejected) 'runner powershell entryMode rejects unsafe args and non-ps1 entries'
        Assert-Test ($builderProbeResult.CmdLine -match '/d /s /c call launcher\.cmd') 'runner cmd entryMode keeps existing launcher command path'
        $finalCleanBlock = [regex]::Match($interactiveRunnerSource, '(?s)\$finalCleanDir = .*?\$largeOutputDir =')
        Assert-Test ($finalCleanBlock.Success -and $finalCleanBlock.Value -match "Read-Host 'Press any key to close this window'" -and $finalCleanBlock.Value -notmatch 'cmd\.exe /d /c pause' -and $finalCleanBlock.Value -match 'delayMs = 300') 'driver final-clean self-test uses readiness-coupled Read-Host prompt'
        Assert-Test ($interactiveRunnerSource -match 'stdout\.txt' -and $interactiveRunnerSource -match 'stderr\.txt' -and $interactiveRunnerSource -match 'result\.json' -and $interactiveRunnerSource -match 'Format-ScenarioEvidencePaths') 'driver self-test writes stdout stderr result evidence paths'
        $vmFinalSource = Get-Content -LiteralPath (Join-Path $ProjectRoot 'scripts\vm-final-acceptance.ps1') -Raw -Encoding UTF8
        Assert-Test ($interactiveRunnerSource -match 'if\s*\(\s*-not\s+\$SkipDriverSelfTest\s*\)' -and $vmFinalSource -match 'if\s*\(\s*\$index\s+-gt\s+0\s*\)\s*\{\s*\$arguments\s*\+=\s*"-SkipDriverSelfTest"\s*\}') 'default interactive acceptance path still executes driver self-test'

        $fallbackScenario = @($scenarioDoc.scenarioSets.Live | Where-Object { $_.id -eq 'live-official-fallback-success' })[0]
        $fallbackFailureText = @($fallbackScenario.failureText)
        $fallbackFailureTextJoined = $fallbackFailureText -join '|'
        $fallbackFailureTextOk = (
            ($fallbackFailureText.Count -ge 13) -and
            ($fallbackFailureTextJoined -match 'PowerShell') -and
            ($fallbackFailureTextJoined -match 'Node\.js') -and
            ($fallbackFailureTextJoined -match 'npm')
        )
        Assert-Test $fallbackFailureTextOk 'Live fallback success scenario fails fast on restart and install-incomplete text'
    }
    finally {
        $env:USERPROFILE = $installerSaved.UserProfile
        $env:APPDATA = $installerSaved.AppData
        $env:LOCALAPPDATA = $installerSaved.LocalAppData
        $env:Path = $installerSaved.ProcessPath
        $env:ProgramFiles = $installerSaved.ProgramFiles
        ${env:ProgramFiles(x86)} = $installerSaved.ProgramFilesX86
        foreach ($installerEnvName in $installerEnvNames) {
            $oldValue = $oldInstallerEnv[$installerEnvName]
            if ($null -eq $oldValue) { Remove-Item -Path "Env:\$installerEnvName" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($installerEnvName, $oldValue, 'Process') }
        }
    }

    # Resume state round-trip preserves parameters and all previous results without registering real tasks.
    $resumePaths = Get-AcceptanceControlPaths -ControlRoot (Join-Path $testRoot 'resume-control') -RunId '20260623-120000-001'
    New-Item -ItemType Directory -Path $resumePaths.Run -Force | Out-Null
    $resumeState = New-TestResumeState -NextScenarioIndex 5
    $resumeState.PendingOwnership = New-AcceptanceOwnership -PathRoots @($owned)
    $taskSpec = Register-AcceptanceResume -Paths $resumePaths -EntryScript (Join-Path $PSScriptRoot 'vm-final-acceptance.ps1') -State $resumeState -ScenarioCount 7 -SkipTaskRegistration
    $roundTrip = Read-AcceptanceResumeState -ControlRoot $resumePaths.Root -ScenarioCount 7
    $sr=New-Object Collections.ArrayList;$cr=New-Object Collections.ArrayList;$rr=New-Object Collections.ArrayList
    Import-AcceptanceResumeResults -State $roundTrip -StageResults $sr -ScenarioResults $cr -CleanupReports $rr
    Assert-Test ($roundTrip.CredentialTarget -eq 'TEST_TARGET' -and $roundTrip.NextScenarioIndex -eq 5 -and $roundTrip.Phase -eq 'resume-cleanup-pending' -and $taskSpec.Arguments -match 'CredentialTarget "TEST_TARGET"' -and $taskSpec.Arguments -match '-AcknowledgeRestart' -and $sr.Count -eq 1 -and $cr.Count -eq 5 -and $rr.Count -eq 1 -and $sr[0].ExitCode -eq 0 -and $cr[0].Stage.Name -eq 'stage-before' -and @($rr[0].Report.Actions).Count -eq 1 -and @($rr[0].Report.Reports).Count -eq 1) 'resume state preserves completed scenario prefix and cleanup result collections'
    $cleanupEvents = New-Object Collections.ArrayList; $executedScenarios = New-Object Collections.ArrayList
    $missingTaskProbe = { param($TaskName) return $false }
    $resumeFlow = Invoke-VmResumeControlFlow -State $roundTrip -ScenarioCount 7 -PendingCleanup {
        [void]$cleanupEvents.Add('cleanup')
        [void](Remove-AcceptanceResume -Paths $resumePaths -TaskExistenceProbe $missingTaskProbe)
        [PSCustomObject]@{ Success = $true }
    }
    $scenarioNames = @('completed-0', 'completed-1', 'completed-2', 'completed-3', 'completed-4', 'next-5', 'next-6')
    for ($resumeIndex = $resumeFlow.NextScenarioIndex; $resumeIndex -lt $scenarioNames.Count; $resumeIndex++) { [void]$executedScenarios.Add($scenarioNames[$resumeIndex]) }
    Assert-Test ($cleanupEvents.Count -eq 1 -and -not (Test-Path -LiteralPath $resumePaths.ResumeState) -and ((@($executedScenarios) -join ',') -eq 'next-5,next-6')) 'resume control flow removes checkpoint and executes only following scenarios'

    # A second resume starts at the terminal index, so completed install/API-like scenarios are not repeated.
    $repeatExecuted = New-Object Collections.ArrayList
    $repeatState = New-TestResumeState -NextScenarioIndex 7
    $repeatFlow = Invoke-VmResumeControlFlow -State $repeatState -ScenarioCount 7 -PendingCleanup { [PSCustomObject]@{ Success = $true } }
    for ($resumeIndex = $repeatFlow.NextScenarioIndex; $resumeIndex -lt $scenarioNames.Count; $resumeIndex++) { [void]$repeatExecuted.Add($scenarioNames[$resumeIndex]) }
    Assert-Test ($repeatExecuted.Count -eq 0) 'repeated resume at terminal checkpoint does not repeat install or API scenarios'

    # Authorization failure occurs before registration, restart, VM probing, or any persistent write.
    $authorizationPaths = Get-AcceptanceControlPaths -ControlRoot (Join-Path $testRoot 'authorization-control') -RunId '20260623-120000-001'
    $savedMode = $Mode; $savedInstallAck = $AcknowledgeRealInstall; $savedRestartAck = $AcknowledgeRestart
    $hadPaths = $null -ne (Get-Variable -Name paths -Scope Script -ErrorAction SilentlyContinue)
    $savedPaths = if ($hadPaths) { Get-Variable -Name paths -Scope Script -ValueOnly } else { $null }
    try {
        $paths = $authorizationPaths
        foreach ($authorizationCase in @(
            [PSCustomObject]@{ Mode = 'TestSafe'; Install = $true; Restart = $true },
            [PSCustomObject]@{ Mode = 'Live'; Install = $false; Restart = $true },
            [PSCustomObject]@{ Mode = 'Live'; Install = $true; Restart = $false }
        )) {
            $Mode = $authorizationCase.Mode; $AcknowledgeRealInstall = $authorizationCase.Install; $AcknowledgeRestart = $authorizationCase.Restart
            $blocked = $false
            try { Invoke-VmAuthorizedRestart -ResumeState (New-TestResumeState) } catch { $blocked = $_.Exception.Message -match 'Automatic restart is disabled' }
            Assert-Test ($blocked -and -not (Test-Path -LiteralPath $authorizationPaths.Root)) "authorization blocks registration and restart: $($authorizationCase.Mode)/$($authorizationCase.Install)/$($authorizationCase.Restart)"
        }
    }
    finally {
        $Mode = $savedMode; $AcknowledgeRealInstall = $savedInstallAck; $AcknowledgeRestart = $savedRestartAck
        if ($hadPaths) { $paths = $savedPaths } else { Remove-Variable -Name paths -Scope Script -ErrorAction SilentlyContinue }
    }

    # SchemaVersion 3 is treated as untrusted persisted input, including numeric boundaries.
    $schemaPaths = Get-AcceptanceControlPaths -ControlRoot (Join-Path $testRoot 'schema-control') -RunId '20260623-120000-001'
    foreach ($validIndex in @(0, 6, 7)) {
        Write-TestResumeState -Paths $schemaPaths -State (New-TestResumeState -NextScenarioIndex $validIndex)
        $validState = Read-AcceptanceResumeState -Path $schemaPaths.ResumeState -ScenarioCount 7
        Assert-Test ([int]$validState.NextScenarioIndex -eq $validIndex) "Schema 3 accepts index boundary $validIndex"
    }
    $scenarioFile = Join-Path $ProjectRoot 'scripts\data\interactive-acceptance-scenarios.json'
    $scenarioDocument = Get-Content -LiteralPath $scenarioFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $orderedTestSafeIds = @($scenarioDocument.scenarioSets.TestSafe | Select-Object -First 2 | ForEach-Object { [string]$_.id })
    Write-TestResumeState -Paths $schemaPaths -State (New-TestResumeState -Mode TestSafe -NextScenarioIndex 2 -ScenarioIds $orderedTestSafeIds)
    $orderedState = Read-AcceptanceResumeState -Path $schemaPaths.ResumeState -ScenarioFile $scenarioFile
    Assert-Test (@($orderedState.ScenarioResults).Count -eq 2) 'Schema 3 accepts completed scenario prefix matching scenario definition order'
    $wrongOrder = Copy-TestResumeState (New-TestResumeState -Mode TestSafe -NextScenarioIndex 2 -ScenarioIds @($orderedTestSafeIds[1], $orderedTestSafeIds[0]))
    Write-TestResumeState -Paths $schemaPaths -State $wrongOrder
    $wrongOrderError = $null
    try { [void](Read-AcceptanceResumeState -Path $schemaPaths.ResumeState -ScenarioFile $scenarioFile) } catch { $wrongOrderError = $_.Exception.Message }
    Assert-Test ($wrongOrderError -and $wrongOrderError.Contains('ScenarioResults[0].Id')) 'Schema 3 rejects resume scenario prefix that does not match scenario definition order'
    $invalidStates = @(
        [PSCustomObject]@{ Field = 'SchemaVersion'; Mutate = { param($s) $s.SchemaVersion = 2 } },
        [PSCustomObject]@{ Field = 'SchemaVersion'; Mutate = { param($s) $s.SchemaVersion = '3' } },
        [PSCustomObject]@{ Field = 'RunId'; Mutate = { param($s) $s.RunId = '..\escape' } },
        [PSCustomObject]@{ Field = 'Mode'; Mutate = { param($s) $s.Mode = 'Unsafe' } },
        [PSCustomObject]@{ Field = 'Version'; Mutate = { param($s) $s.Version = 'latest' } },
        [PSCustomObject]@{ Field = 'CredentialTarget'; Mutate = { param($s) $s.CredentialTarget = 'SECRET VALUE' } },
        [PSCustomObject]@{ Field = 'AcknowledgeRestart'; Mutate = { param($s) $s.AcknowledgeRestart = $false } },
        [PSCustomObject]@{ Field = 'AcknowledgeRealInstall'; Mutate = { param($s) $s.AcknowledgeRealInstall = 'true' } },
        [PSCustomObject]@{ Field = 'Phase'; Mutate = { param($s) $s.Phase = 'scenario-post-cleanup' } },
        [PSCustomObject]@{ Field = 'NextScenarioIndex'; Mutate = { param($s) $s.NextScenarioIndex = -1 } },
        [PSCustomObject]@{ Field = 'NextScenarioIndex'; Mutate = { param($s) $s.NextScenarioIndex = 8 } },
        [PSCustomObject]@{ Field = 'NextScenarioIndex'; Mutate = { param($s) $s.NextScenarioIndex = 1.5 } },
        [PSCustomObject]@{ Field = 'StageResults'; Mutate = { param($s) $s.StageResults = 'not-an-array' } },
        [PSCustomObject]@{ Field = 'StageResults[0].Name'; Mutate = { param($s) $s.StageResults[0].Name = 7 } },
        [PSCustomObject]@{ Field = 'StageResults[0].ExitCode'; Mutate = { param($s) $s.StageResults[0].ExitCode = '0' } },
        [PSCustomObject]@{ Field = 'StageResults[0].TimedOut'; Mutate = { param($s) $s.StageResults[0].TimedOut = 'false' } },
        [PSCustomObject]@{ Field = 'StageResults[0].DurationSec'; Mutate = { param($s) $s.StageResults[0].DurationSec = -1 } },
        [PSCustomObject]@{ Field = 'StageResults[0].Stdout'; Mutate = { param($s) $s.StageResults[0].Stdout = 7 } },
        [PSCustomObject]@{ Field = 'StageResults[0].Stderr'; Mutate = { param($s) $s.StageResults[0].Stderr = $null } },
        [PSCustomObject]@{ Field = 'StageResults[0].Result'; Mutate = { param($s) $s.StageResults[0].Result = @() } },
        [PSCustomObject]@{ Field = 'ScenarioResults'; Mutate = { param($s) $s.ScenarioResults = @() } },
        [PSCustomObject]@{ Field = 'ScenarioResults.Id'; Mutate = { param($s) $s.ScenarioResults = @($s.ScenarioResults[0], $s.ScenarioResults[0]); $s.NextScenarioIndex = 2 } },
        [PSCustomObject]@{ Field = 'ScenarioResults[0].Mode'; Mutate = { param($s) $s.Mode = 'TestSafe'; $s.AcknowledgeRealInstall = $false; $s.AcknowledgeRestart = $false; $s.ScenarioResults[0].Mode = 'Live' } },
        [PSCustomObject]@{ Field = 'ScenarioResults[0].Id'; Mutate = { param($s) $s.ScenarioResults[0].Id = 7 } },
        [PSCustomObject]@{ Field = 'ScenarioResults[0].Mode'; Mutate = { param($s) $s.ScenarioResults[0].Mode = $true } },
        [PSCustomObject]@{ Field = 'ScenarioResults[0].Status'; Mutate = { param($s) $s.ScenarioResults[0].Status = 'UNKNOWN' } },
        [PSCustomObject]@{ Field = 'ScenarioResults[0].Stage'; Mutate = { param($s) $s.ScenarioResults[0].Stage = 'not-an-object' } },
        [PSCustomObject]@{ Field = 'ScenarioResults[0].Stage.ExitCode'; Mutate = { param($s) $s.ScenarioResults[0].Stage.ExitCode = 1.5 } },
        [PSCustomObject]@{ Field = 'ScenarioResults[0].Error'; Mutate = { param($s) $s.ScenarioResults[0].Error = 7 } },
        [PSCustomObject]@{ Field = 'CleanupReports[0].Scenario'; Mutate = { param($s) $s.CleanupReports[0].Scenario = 7 } },
        [PSCustomObject]@{ Field = 'CleanupReports[0].Phase'; Mutate = { param($s) $s.CleanupReports[0].Phase = $false } },
        [PSCustomObject]@{ Field = 'CleanupReports[0].Report.Success'; Mutate = { param($s) $s.CleanupReports[0].Report.Success = 'true' } },
        [PSCustomObject]@{ Field = 'CleanupReports[0].Report.Actions'; Mutate = { param($s) $s.CleanupReports[0].Report.Actions = 'not-an-array' } },
        [PSCustomObject]@{ Field = 'CleanupReports[0].Report.Actions'; Mutate = { param($s) $s.CleanupReports[0].Report.Actions = @(7) } },
        [PSCustomObject]@{ Field = 'CleanupReports[0].Report.Errors'; Mutate = { param($s) $s.CleanupReports[0].Report.Errors = @(7) } },
        [PSCustomObject]@{ Field = 'CleanupReports[0].Report.Reports'; Mutate = { param($s) $s.CleanupReports[0].Report.Reports = $null } },
        [PSCustomObject]@{ Field = 'CleanupReports[0].Report.Ownership'; Mutate = { param($s) $s.CleanupReports[0].Report.Ownership = 'not-an-object' } },
        [PSCustomObject]@{ Field = 'CleanupReports[0].Report.Ownership.PathRoots'; Mutate = { param($s) $s.CleanupReports[0].Report.Ownership.PathRoots = @(7) } },
        [PSCustomObject]@{ Field = 'PendingOwnership.PathRoots'; Mutate = { param($s) $s.PendingOwnership.PathRoots = 'C:\unsafe' } },
        [PSCustomObject]@{ Field = 'PendingOwnership.ProcessIds'; Mutate = { param($s) $s.PendingOwnership.ProcessIds = @('123') } },
        [PSCustomObject]@{ Field = 'SavedAt'; Mutate = { param($s) $s.SavedAt = 'not-a-time' } },
        [PSCustomObject]@{ Field = 'Error'; Mutate = { param($s) $s.Error = 7 } }
    )
    foreach ($invalidCase in $invalidStates) {
        $invalidState = Copy-TestResumeState (New-TestResumeState)
        & $invalidCase.Mutate $invalidState
        Write-TestResumeState -Paths $schemaPaths -State $invalidState
        $invalidError = $null
        try { [void](Read-AcceptanceResumeState -Path $schemaPaths.ResumeState -ScenarioCount 7) } catch { $invalidError = $_.Exception.Message }
        Assert-Test ($invalidError -and $invalidError.Contains($schemaPaths.ResumeState) -and $invalidError.Contains($invalidCase.Field)) "Schema 3 rejects invalid $($invalidCase.Field) with path and field evidence"
    }
    $missingMode = Copy-TestResumeState (New-TestResumeState); $missingMode.PSObject.Properties.Remove('Mode')
    Write-TestResumeState -Paths $schemaPaths -State $missingMode
    $missingError = $null
    try { [void](Read-AcceptanceResumeState -Path $schemaPaths.ResumeState -ScenarioCount 7) } catch { $missingError = $_.Exception.Message }
    Assert-Test ($missingError -and $missingError.Contains($schemaPaths.ResumeState) -and $missingError -match "field 'Mode' is missing") 'Schema 3 rejects missing required field before side effects'

    # Registration is transactional at each write/task boundary and never calls real Task Scheduler APIs.
    $registrationSuccess = Invoke-TestRegistrationFault -Name 'success'
    Assert-Test (-not $registrationSuccess.Error -and $registrationSuccess.Tasks.Count -eq 2 -and $registrationSuccess.Report.Success) 'registration success verifies both injected tasks and writes success evidence'
    $sameCheckpoint = Invoke-TestRegistrationFault -Name 'same-checkpoint' -Fault ExistingSameState
    Assert-Test (-not $sameCheckpoint.Error -and $sameCheckpoint.Tasks.Count -eq 2 -and $sameCheckpoint.Report.Success) 'registration accepts a valid owned checkpoint for the same RunId'
    foreach ($checkpointCase in @('ExistingDifferentState','ExistingCorruptState')) {
        $checkpointFailure = Invoke-TestRegistrationFault -Name $checkpointCase -Fault $checkpointCase
        $checkpointBytesAfter = [IO.File]::ReadAllBytes($checkpointFailure.Paths.ResumeState)
        Assert-Test ($checkpointFailure.Error -and $checkpointFailure.Tasks.Count -eq 0 -and $checkpointFailure.Report -and -not $checkpointFailure.Report.Success -and ([Convert]::ToBase64String($checkpointBytesAfter) -ceq [Convert]::ToBase64String($checkpointFailure.ExistingStateBytes)) -and -not (@($checkpointFailure.Events) -contains 'write-state')) "registration rejects $checkpointCase checkpoint without overwrite or task side effects"
    }
    foreach ($registrationCase in @(
        [PSCustomObject]@{ Name = 'state'; Fault = 'State' },
        [PSCustomObject]@{ Name = 'user'; Fault = 'UserTask' },
        [PSCustomObject]@{ Name = 'bootstrap'; Fault = 'Bootstrap' },
        [PSCustomObject]@{ Name = 'system'; Fault = 'SystemTask' },
        [PSCustomObject]@{ Name = 'verify-missing'; Fault = 'VerifyMissing' },
        [PSCustomObject]@{ Name = 'verify-mismatch'; Fault = 'VerifyMismatch' }
    )) {
        $registrationFailure = Invoke-TestRegistrationFault -Name $registrationCase.Name -Fault $registrationCase.Fault
        Assert-Test ($registrationFailure.Error -and $registrationFailure.Tasks.Count -eq 0 -and $registrationFailure.Report -and -not $registrationFailure.Report.Success -and (Test-Path -LiteralPath $registrationFailure.Paths.ResumeState) -eq ($registrationCase.Fault -ne 'State')) "registration $($registrationCase.Fault) failure rolls back only created resources and preserves state"
    }
    $rollbackFailure = Invoke-TestRegistrationFault -Name 'rollback-failure' -Fault SystemTask -RollbackFails
    Assert-Test ($rollbackFailure.Error -match 'rollback/report errors' -and $rollbackFailure.Tasks.Count -eq 1 -and @($rollbackFailure.Report.RollbackErrors).Count -gt 0 -and (Test-Path -LiteralPath $rollbackFailure.Paths.ResumeState)) 'registration rollback failure preserves original error, task state, and rollback evidence'
    $queryFailure = Invoke-TestRegistrationFault -Name 'query-failure' -Fault Query
    Assert-Test ($queryFailure.Error -match 'task query RPC failure' -and $queryFailure.Tasks.Count -eq 0 -and @($queryFailure.Report.RollbackErrors).Count -eq 0 -and -not (Test-Path -LiteralPath $queryFailure.Paths.ResumeState)) 'registration preflight task query failure occurs before persistent side effects'
    $verificationQueryFailure = Invoke-TestRegistrationFault -Name 'verification-query-failure' -Fault QueryAfterRegistration
    Assert-Test ($verificationQueryFailure.Error -match 'task query RPC failure' -and $verificationQueryFailure.Tasks.Count -eq 2 -and @($verificationQueryFailure.Report.RollbackErrors).Count -eq 2 -and (Test-Path -LiteralPath $verificationQueryFailure.Paths.ResumeState)) 'registration verification query failure remains fail-closed with rollback evidence'
    $registrationReportFailure = Invoke-TestRegistrationFault -Name 'report-failure' -Fault Report
    Assert-Test ($registrationReportFailure.Error -match 'registration report write failure' -and $registrationReportFailure.Tasks.Count -eq 0 -and -not (Test-Path -LiteralPath $registrationReportFailure.Paths.ResumeBootstrap) -and (Test-Path -LiteralPath $registrationReportFailure.Paths.ResumeState)) 'registration report failure rolls back tasks and bootstrap while preserving state'
    $preexisting = Invoke-TestRegistrationFault -Name 'preexisting' -Fault State -SeedPreexistingTasks
    Assert-Test ($preexisting.Error -and $preexisting.Tasks.Count -eq 2 -and $preexisting.Tasks[$preexisting.Paths.ResumeTask].Arguments -eq 'PREEXISTING-SYSTEM' -and -not (@($preexisting.Events) -match '^delete-')) 'registration never deletes preexisting unowned tasks'

    # Cleanup is fail-closed for query, delete, verification, file, report, and repeated-call paths.
    $removalSuccess = Invoke-TestRemovalFault -Name 'success'
    Assert-Test (-not $removalSuccess.Error -and $removalSuccess.Result.Success -and $removalSuccess.Tasks.Count -eq 0 -and -not (Test-Path -LiteralPath $removalSuccess.Paths.ResumeState) -and -not (Test-Path -LiteralPath $removalSuccess.Paths.ResumeBootstrap) -and $removalSuccess.Report.Success) 'resume cleanup success removes tasks, state, bootstrap and writes evidence'
    $missingProbe = { param($TaskName) return $false }
    $repeatRemoval = Remove-AcceptanceResume -Paths $removalSuccess.Paths -TaskExistenceProbe $missingProbe
    Assert-Test ($repeatRemoval.Success -and $repeatRemoval.State -eq 'Missing' -and $repeatRemoval.Bootstrap -eq 'Missing') 'resume cleanup is idempotent on repeated invocation'
    $keepState = Invoke-TestRemovalFault -Name 'keep-state' -KeepState
    Assert-Test (-not $keepState.Error -and $keepState.Result.Success -and (Test-Path -LiteralPath $keepState.Paths.ResumeState) -and -not (Test-Path -LiteralPath $keepState.Paths.ResumeBootstrap) -and $keepState.Result.State -eq 'Kept') 'KeepState retains only state after strict task and bootstrap cleanup'
    foreach ($removalFault in @('Query','Timeout','NonZero','TaskStillExists','StateDelete','StateStillExists','BootstrapDelete','BootstrapStillExists')) {
        $removalFailure = Invoke-TestRemovalFault -Name $removalFault -Fault $removalFault
        Assert-Test ($removalFailure.Error -and $removalFailure.Report -and -not $removalFailure.Report.Success -and (Test-Path -LiteralPath $removalFailure.Paths.ResumeState)) "resume cleanup $removalFault failure preserves state and failure evidence"
    }
    $cleanupReportFailure = Invoke-TestRemovalFault -Name 'report-failure' -Fault Report
    Assert-Test ($cleanupReportFailure.Error -match 'cleanup report write failed' -and (Test-Path -LiteralPath $cleanupReportFailure.Paths.ResumeState) -and $cleanupReportFailure.Tasks.Count -eq 0 -and -not (Test-Path -LiteralPath $cleanupReportFailure.Paths.ResumeBootstrap)) 'cleanup report write failure restores state and cannot report success'

    # Release sensitive scanning must preserve diagnostics without emitting raw API keys.
    $fakeKey = 'sk-ProdLeakForTest' + ('0' * 12) + 'abcd'
    $scanContent = "first line`nDEEPSEEK_API_KEY=$fakeKey`n"
    $apiHits = [System.Collections.Generic.List[object]]::new()
    Add-ApiKeyHitsFromContent -Content $scanContent -DisplayPath 'fixtures\leak.env' -Hits $apiHits -DangerPatterns @('sk-[A-Za-z0-9]{20,}', 'DEEPSEEK_API_KEY.*sk-[A-Za-z0-9]{20,}') -SafePlaceholders @('sk-xxxx')
    $renderedHits = @($apiHits | ForEach-Object { "file=$($_.File); line=$($_.Line); type=$($_.Type); redacted=$($_.Redacted)" }) -join "`n"
    Assert-Test ($apiHits.Count -gt 0 -and $renderedHits -notmatch [regex]::Escape($fakeKey) -and $renderedHits -match '<redacted-api-key: suffix=abcd>' -and $renderedHits -match 'file=fixtures\\leak\.env' -and $renderedHits -match 'line=2' -and $renderedHits -match 'type=DEEPSEEK_API_KEY') 'API key scan reports file line type and redacted suffix without leaking the full key'

    # Final PASS is published only after evidence and resume cleanup complete. Summary failures are retried as FAIL.
    $lifecycleEvents = New-Object Collections.ArrayList
    $summaryFactory = {
        param($Status, $ErrorText)
        [PSCustomObject]@{ Status = $Status; Error = $ErrorText }
    }
    $lifecycleSuccess = Complete-VmAcceptanceLifecycle -PriorError $null `
        -EvidenceWriter { [void]$lifecycleEvents.Add('evidence') } `
        -FinalResumeCleanup { [void]$lifecycleEvents.Add('cleanup') } `
        -SummaryFactory $summaryFactory `
        -SummaryWriter { param($Summary) [void]$lifecycleEvents.Add("summary-$($Summary.Status)") }
    Assert-Test ($lifecycleSuccess.Status -eq 'PASS' -and $lifecycleSuccess.ExitCode -eq 0 -and $lifecycleSuccess.SummaryWritten -and ((@($lifecycleEvents) -join ',') -eq 'evidence,cleanup,summary-PASS')) 'final lifecycle publishes PASS only after evidence and resume cleanup'

    $cleanupLifecycle = Complete-VmAcceptanceLifecycle -PriorError $null `
        -EvidenceWriter { } -FinalResumeCleanup { throw 'INJECTED final cleanup failure' } `
        -SummaryFactory $summaryFactory -SummaryWriter { param($Summary) $script:capturedCleanupSummary = $Summary }
    Assert-Test ($cleanupLifecycle.Status -eq 'FAIL' -and $cleanupLifecycle.ExitCode -eq 1 -and $cleanupLifecycle.SummaryWritten -and $capturedCleanupSummary.Status -eq 'FAIL' -and $capturedCleanupSummary.Error -match 'final resume cleanup failed') 'final cleanup failure writes FAIL summary and returns nonzero exit'

    $evidenceCleanupCalls = 0
    $evidenceLifecycle = Complete-VmAcceptanceLifecycle -PriorError $null `
        -EvidenceWriter { throw 'INJECTED final evidence failure' } -FinalResumeCleanup { $script:evidenceCleanupCalls++ } `
        -SummaryFactory $summaryFactory -SummaryWriter { param($Summary) $script:capturedEvidenceSummary = $Summary }
    Assert-Test ($evidenceLifecycle.Status -eq 'FAIL' -and $evidenceLifecycle.ExitCode -eq 1 -and $evidenceCleanupCalls -eq 0 -and $capturedEvidenceSummary.Status -eq 'FAIL' -and $capturedEvidenceSummary.Error -match 'final evidence write failed') 'final evidence failure preserves resume state by skipping cleanup and writes FAIL summary'

    $priorErrorCleanupCalls = 0
    $priorErrorLifecycle = Complete-VmAcceptanceLifecycle -PriorError 'INJECTED prior run failure' `
        -EvidenceWriter { } -FinalResumeCleanup { $script:priorErrorCleanupCalls++ } `
        -SummaryFactory $summaryFactory -SummaryWriter { param($Summary) $script:capturedPriorErrorSummary = $Summary }
    Assert-Test ($priorErrorLifecycle.Status -eq 'FAIL' -and $priorErrorLifecycle.ExitCode -eq 1 -and $priorErrorCleanupCalls -eq 1 -and $capturedPriorErrorSummary.Error -match 'prior run failure') 'prior run failure still attempts final resume cleanup before FAIL summary'

    $summaryWriteAttempts = 0; $persistedSummaries = New-Object Collections.ArrayList
    $summaryRetryLifecycle = Complete-VmAcceptanceLifecycle -PriorError $null `
        -EvidenceWriter { } -FinalResumeCleanup { } -SummaryFactory $summaryFactory `
        -SummaryWriter {
            param($Summary)
            $script:summaryWriteAttempts++
            if ($script:summaryWriteAttempts -eq 1) { throw 'INJECTED PASS summary write failure' }
            [void]$persistedSummaries.Add($Summary)
        }
    Assert-Test ($summaryRetryLifecycle.Status -eq 'FAIL' -and $summaryRetryLifecycle.ExitCode -eq 1 -and $summaryRetryLifecycle.SummaryWritten -and $summaryWriteAttempts -eq 2 -and $persistedSummaries.Count -eq 1 -and $persistedSummaries[0].Status -eq 'FAIL') 'PASS summary write failure retries only as FAIL and returns nonzero exit'

    $summaryHardFailure = Complete-VmAcceptanceLifecycle -PriorError $null `
        -EvidenceWriter { } -FinalResumeCleanup { } -SummaryFactory $summaryFactory `
        -SummaryWriter { param($Summary) throw 'INJECTED persistent summary failure' }
    Assert-Test ($summaryHardFailure.Status -eq 'FAIL' -and $summaryHardFailure.ExitCode -eq 1 -and -not $summaryHardFailure.SummaryWritten -and $summaryHardFailure.Error -match 'FAIL summary write failed') 'persistent summary failure cannot leave PASS or zero exit'

    # The same outer finally pattern used by vm-final releases the instance lock after each lifecycle outcome.
    $lifecycleLockRoot = Join-Path $testRoot 'lifecycle-lock'
    foreach ($fault in @('cleanup', 'summary')) {
        $lifecycleLock = Enter-AcceptanceInstanceLock -ControlRoot $lifecycleLockRoot
        try {
            if ($fault -eq 'cleanup') {
                [void](Complete-VmAcceptanceLifecycle -PriorError $null -EvidenceWriter { } -FinalResumeCleanup { throw 'cleanup' } -SummaryFactory $summaryFactory -SummaryWriter { param($Summary) })
            }
            else {
                [void](Complete-VmAcceptanceLifecycle -PriorError $null -EvidenceWriter { } -FinalResumeCleanup { } -SummaryFactory $summaryFactory -SummaryWriter { param($Summary) throw 'summary' })
            }
        }
        finally { Exit-AcceptanceInstanceLock -Lock $lifecycleLock }
        $reacquired = Enter-AcceptanceInstanceLock -ControlRoot $lifecycleLockRoot
        Exit-AcceptanceInstanceLock -Lock $reacquired
    }
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $lifecycleLockRoot '.acceptance.lock'))) 'instance lock is released after final cleanup and summary failure paths'

    # Locked owned path produces LOCKED_PATH evidence and resumable state, without rebooting.
    $lockedRoot = Join-Path $testRoot 'locked-root'; New-Item -ItemType Directory -Path $lockedRoot -Force | Out-Null
    $lockedBefore = New-TestSnapshot (Get-AcceptanceFileState -Roots @($lockedRoot) -CaptureBytes -BackupRoot (Join-Path $testRoot 'locked-baseline'))
    $lockedFile = Join-Path $lockedRoot 'locked.txt'; Set-Content -LiteralPath $lockedFile -Value 'locked'
    $lockedAfter = New-TestSnapshot (Get-AcceptanceFileState -Roots @($lockedRoot)); $lockedDelta=Compare-AcceptanceSnapshot $lockedBefore $lockedAfter
    $handle=New-Object IO.FileStream($lockedFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try {
        $lockedReset=Reset-AcceptanceEnvironment -Baseline $lockedBefore -Current $lockedAfter -Delta $lockedDelta -ProjectRoot $ProjectRoot -ControlRoot (Join-Path $testRoot 'control-d') -ResultRoot (Join-Path $testRoot 'results-d') -AllowedCleanupRoots @($lockedRoot) -ProtectedProcessIds @($PID) -Ownership (New-AcceptanceOwnership -PathRoots @($lockedRoot))
        $lockedRetry=Reset-AcceptanceEnvironment -Baseline $lockedBefore -Current $lockedAfter -Delta $lockedDelta -ProjectRoot $ProjectRoot -ControlRoot (Join-Path $testRoot 'control-d') -ResultRoot (Join-Path $testRoot 'results-d') -AllowedCleanupRoots @($lockedRoot) -ProtectedProcessIds @($PID) -Ownership (New-AcceptanceOwnership -PathRoots @($lockedRoot))
    }
    finally { $handle.Dispose() }
    Assert-Test (-not $lockedReset.Success -and (@($lockedReset.Errors) -match '^LOCKED_PATH:') -and -not $lockedRetry.Success -and (@($lockedRetry.Errors) -match '^LOCKED_PATH:')) 'locked path and repeated pending cleanup produce resumable LOCKED_PATH evidence'
    $unlockedRetry=Reset-AcceptanceEnvironment -Baseline $lockedBefore -Current $lockedAfter -Delta $lockedDelta -ProjectRoot $ProjectRoot -ControlRoot (Join-Path $testRoot 'control-d') -ResultRoot (Join-Path $testRoot 'results-d') -AllowedCleanupRoots @($lockedRoot) -ProtectedProcessIds @($PID) -Ownership (New-AcceptanceOwnership -PathRoots @($lockedRoot))
    Assert-Test ($unlockedRetry.Success -and -not (Test-Path -LiteralPath $lockedFile)) 'pending cleanup succeeds after locked path is released'

    # Stage timeout preserves partial stdout, stderr, and result metadata.
    $stageEvidence=Join-Path $testRoot 'stage-evidence';New-Item -ItemType Directory -Path $stageEvidence -Force|Out-Null
    $helper=Join-Path $testRoot 'timeout-helper.ps1'; @' 
Write-Output 'STDOUT-BEFORE-TIMEOUT'
[Console]::Error.WriteLine('STDERR-BEFORE-TIMEOUT')
Start-Sleep -Seconds 30
'@.TrimStart() | Set-Content -LiteralPath $helper -Encoding UTF8
    $timeoutThrown=$false
    try { Invoke-VmStage -Name 'timeout-proof' -FilePath 'powershell.exe' -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$helper) -TimeoutSec 1 -EvidenceRoot $stageEvidence }
    catch { $timeoutThrown=$true }
    $timeoutResult=Get-Content (Join-Path $stageEvidence 'timeout-proof.result.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert-Test ($timeoutThrown -and $timeoutResult.TimedOut -and (Get-Content (Join-Path $stageEvidence 'timeout-proof.stdout.txt') -Raw) -match 'STDOUT-BEFORE-TIMEOUT' -and (Get-Content (Join-Path $stageEvidence 'timeout-proof.stderr.txt') -Raw) -match 'STDERR-BEFORE-TIMEOUT') 'timeout preserves stdout stderr and metadata'

    $capturedTimeoutHelper=Join-Path $testRoot 'captured-timeout-helper.ps1'; @'
Write-Output 'CAPTURED-STDOUT-BEFORE-TIMEOUT'
[Console]::Error.WriteLine('CAPTURED-STDERR-BEFORE-TIMEOUT')
Start-Sleep -Seconds 30
'@.TrimStart() | Set-Content -LiteralPath $capturedTimeoutHelper -Encoding UTF8
    $capturedTimeout=Invoke-AcceptanceCapturedCommand -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$capturedTimeoutHelper) -TimeoutSec 1
    Assert-Test ($capturedTimeout.TimedOut -and $capturedTimeout.StdOut -match 'CAPTURED-STDOUT-BEFORE-TIMEOUT' -and $capturedTimeout.StdErr -match 'CAPTURED-STDERR-BEFORE-TIMEOUT') 'captured command timeout preserves stdout stderr evidence'

    # Real environment must be byte-identical to the baseline captured before any test ran.
    Assert-Test ([Environment]::GetEnvironmentVariable('Path', 'User') -ceq $realEnvBaseline.UserPath) 'real user PATH unchanged across all tests'
    Assert-Test ([Environment]::GetEnvironmentVariable('Path', 'Machine') -ceq $realEnvBaseline.MachinePath) 'real machine PATH unchanged across all tests'
    Assert-Test ($env:Path -ceq $realEnvBaseline.ProcessPath) 'real process PATH unchanged across all tests'
    $settingsExistsNow = Test-Path -LiteralPath $realSettingsPath
    $settingsLengthNow = if ($settingsExistsNow) { (Get-Item -LiteralPath $realSettingsPath -Force).Length } else { 0 }
    $settingsHashNow = if ($settingsExistsNow) { (Get-FileHash -LiteralPath $realSettingsPath -Algorithm SHA256).Hash } else { $null }
    Assert-Test (($settingsExistsNow -eq $realEnvBaseline.SettingsExists) -and ($settingsLengthNow -eq $realEnvBaseline.SettingsLength) -and ($settingsHashNow -eq $realEnvBaseline.SettingsHash)) 'real settings.json unchanged across all tests'

    Write-Host "[vm-test] PASS: $($passes.Count) functional checks" -ForegroundColor Green
}
finally {
    $env:USERPROFILE=$oldProfile;$env:APPDATA=$oldAppData;$env:LOCALAPPDATA=$oldLocalAppData;$env:Path=$oldProcessPath
    $env:ProgramFiles=$oldProgramFiles;${env:ProgramFiles(x86)}=$oldProgramFilesX86
    foreach ($installerEnvName in $installerEnvNames) {
        $oldValue = $oldInstallerEnv[$installerEnvName]
        if ($null -eq $oldValue) { Remove-Item -Path "Env:\$installerEnvName" -ErrorAction SilentlyContinue }
        else { [Environment]::SetEnvironmentVariable($installerEnvName, $oldValue, 'Process') }
    }
    if ($null -eq $oldTestDesktop) { Remove-Item Env:\CCDI_TEST_DESKTOP -ErrorAction SilentlyContinue } else { $env:CCDI_TEST_DESKTOP=$oldTestDesktop }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
