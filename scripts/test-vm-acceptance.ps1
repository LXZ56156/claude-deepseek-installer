[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$module = Join-Path $PSScriptRoot 'lib\AcceptanceEnvironment.ps1'
. $module

$oldImport = $env:CCDI_ACCEPTANCE_IMPORT_ONLY
$env:CCDI_ACCEPTANCE_IMPORT_ONLY = '1'
try { . (Join-Path $PSScriptRoot 'vm-final-acceptance.ps1') }
finally { if ($null -eq $oldImport) { Remove-Item Env:\CCDI_ACCEPTANCE_IMPORT_ONLY -ErrorAction SilentlyContinue } else { $env:CCDI_ACCEPTANCE_IMPORT_ONLY = $oldImport } }

$testRoot = Join-Path $env:TEMP ('ccdi-vm-acceptance-test-' + [guid]::NewGuid().ToString('N'))
$oldProfile = $env:USERPROFILE; $oldAppData = $env:APPDATA; $oldLocalAppData = $env:LOCALAPPDATA
$oldTestDesktop = $env:CCDI_TEST_DESKTOP; $oldProcessPath = $env:Path
$oldUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
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

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

# Capture the real environment before any test runs. Every assertion below must leave
# these byte-identical: no real User/Machine/Process PATH drift and no real settings.json drift.
$realSettingsPath = Join-Path $oldProfile '.claude\settings.json'
$realEnvBaseline = [ordered]@{
    UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    MachinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    ProcessPath = $env:Path
    SettingsExists = Test-Path -LiteralPath $realSettingsPath
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

    # Resume state round-trip preserves parameters and all previous results without registering real tasks.
    $resumePaths = Get-AcceptanceControlPaths -ControlRoot (Join-Path $testRoot 'resume-control') -RunId 'roundtrip-run'
    New-Item -ItemType Directory -Path $resumePaths.Run -Force | Out-Null
    $resumeState = [ordered]@{ SchemaVersion=3;RunId='roundtrip-run';Mode='Live';Version='1.3.3';CredentialTarget='TEST_TARGET';AcknowledgeRealInstall=$true;AcknowledgeRestart=$true;Phase='resume-cleanup-pending';NextScenarioIndex=5;StageResults=@(@{Name='stage-before'});ScenarioResults=@(@{Id='scenario-before';Status='PASS'});CleanupReports=@(@{Scenario='cleanup-before'});PendingOwnership=(New-AcceptanceOwnership -PathRoots @($owned)) }
    $taskSpec = Register-AcceptanceResume -Paths $resumePaths -EntryScript (Join-Path $PSScriptRoot 'vm-final-acceptance.ps1') -State $resumeState -SkipTaskRegistration
    $roundTrip = Read-AcceptanceResumeState -ControlRoot $resumePaths.Root
    $sr=New-Object Collections.ArrayList;$cr=New-Object Collections.ArrayList;$rr=New-Object Collections.ArrayList
    Import-AcceptanceResumeResults -State $roundTrip -StageResults $sr -ScenarioResults $cr -CleanupReports $rr
    Assert-Test ($roundTrip.CredentialTarget -eq 'TEST_TARGET' -and $roundTrip.NextScenarioIndex -eq 5 -and $roundTrip.Phase -eq 'resume-cleanup-pending' -and $taskSpec.Arguments -match 'CredentialTarget "TEST_TARGET"' -and $taskSpec.Arguments -match '-AcknowledgeRestart' -and $sr.Count -eq 1 -and $cr.Count -eq 1 -and $rr.Count -eq 1) 'resume state starts after completed scenario and preserves prior results'
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
    Assert-Test (-not (Test-VmAutomaticRestartAllowed -AcceptanceMode 'TestSafe' -RealInstallAcknowledged $true -RestartAcknowledged $true)) 'TestSafe can never authorize automatic restart'
    Assert-Test (-not (Test-VmAutomaticRestartAllowed -AcceptanceMode 'Live' -RealInstallAcknowledged $true -RestartAcknowledged $false)) 'Live restart requires independent acknowledgement'

    $legacyPaths = Get-AcceptanceControlPaths -ControlRoot (Join-Path $testRoot 'legacy-resume-control') -RunId 'legacy-run'
    New-Item -ItemType Directory -Path $legacyPaths.Root -Force | Out-Null
    ([ordered]@{ SchemaVersion=2;RunId='legacy-run';Phase='scenario-post-cleanup';NextScenarioIndex=4 } | ConvertTo-Json) | Set-Content -LiteralPath $legacyPaths.ResumeState -Encoding UTF8
    $legacyRejected = $false
    try { [void](Read-AcceptanceResumeState -ControlRoot $legacyPaths.Root) } catch { $legacyRejected = $_.Exception.Message -match 'Only SchemaVersion 3 is accepted' }
    Assert-Test $legacyRejected 'legacy resume schema is rejected before control flow'

    $failedDeletePaths = Get-AcceptanceControlPaths -ControlRoot (Join-Path $testRoot 'failed-delete-control') -RunId 'failed-delete-run'
    New-Item -ItemType Directory -Path $failedDeletePaths.Root -Force | Out-Null
    'state-must-remain' | Set-Content -LiteralPath $failedDeletePaths.ResumeState -Encoding UTF8
    $deleteEvents = New-Object Collections.ArrayList
    $failedDeleteInvoker = {
        param($FilePath, $Arguments)
        [void]$deleteEvents.Add([string]$Arguments[0])
        return [PSCustomObject]@{ TimedOut=$false;ExitCode=5;StdOut='';StdErr='ERROR: Access is denied.' }
    }
    $existingTaskProbe = { param($TaskName) return $true }
    $deleteFailureBlocked = $false
    try { [void](Remove-AcceptanceResume -Paths $failedDeletePaths -TaskCommandInvoker $failedDeleteInvoker -TaskExistenceProbe $existingTaskProbe) } catch { $deleteFailureBlocked = $_.Exception.Message -match 'Failed to delete resume task' }
    $deleteEvidence = Get-Content -LiteralPath $failedDeletePaths.ResumeCleanupReport -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Test ($deleteFailureBlocked -and (Test-Path -LiteralPath $failedDeletePaths.ResumeState) -and -not $deleteEvidence.Success -and $deleteEvents.Count -eq 1) 'task deletion failure preserves resume state and evidence'

    # Locked owned path produces LOCKED_PATH evidence and resumable state, without rebooting.
    $lockedRoot = Join-Path $testRoot 'locked-root'; New-Item -ItemType Directory -Path $lockedRoot -Force | Out-Null
    $lockedBefore = New-TestSnapshot (Get-AcceptanceFileState -Roots @($lockedRoot) -CaptureBytes -BackupRoot (Join-Path $testRoot 'locked-baseline'))
    $lockedFile = Join-Path $lockedRoot 'locked.txt'; Set-Content -LiteralPath $lockedFile -Value 'locked'
    $lockedAfter = New-TestSnapshot (Get-AcceptanceFileState -Roots @($lockedRoot)); $lockedDelta=Compare-AcceptanceSnapshot $lockedBefore $lockedAfter
    $handle=New-Object IO.FileStream($lockedFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try { $lockedReset=Reset-AcceptanceEnvironment -Baseline $lockedBefore -Current $lockedAfter -Delta $lockedDelta -ProjectRoot $ProjectRoot -ControlRoot (Join-Path $testRoot 'control-d') -ResultRoot (Join-Path $testRoot 'results-d') -AllowedCleanupRoots @($lockedRoot) -ProtectedProcessIds @($PID) -Ownership (New-AcceptanceOwnership -PathRoots @($lockedRoot)) }
    finally { $handle.Dispose() }
    Assert-Test (-not $lockedReset.Success -and (@($lockedReset.Errors) -match '^LOCKED_PATH:')) 'locked path produces resumable cleanup failure'

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

    # Real environment must be byte-identical to the baseline captured before any test ran.
    Assert-Test ([Environment]::GetEnvironmentVariable('Path', 'User') -ceq $realEnvBaseline.UserPath) 'real user PATH unchanged across all tests'
    Assert-Test ([Environment]::GetEnvironmentVariable('Path', 'Machine') -ceq $realEnvBaseline.MachinePath) 'real machine PATH unchanged across all tests'
    Assert-Test ($env:Path -ceq $realEnvBaseline.ProcessPath) 'real process PATH unchanged across all tests'
    $settingsExistsNow = Test-Path -LiteralPath $realSettingsPath
    $settingsHashNow = if ($settingsExistsNow) { (Get-FileHash -LiteralPath $realSettingsPath -Algorithm SHA256).Hash } else { $null }
    Assert-Test (($settingsExistsNow -eq $realEnvBaseline.SettingsExists) -and ($settingsHashNow -eq $realEnvBaseline.SettingsHash)) 'real settings.json unchanged across all tests'

    Write-Host "[vm-test] PASS: $($passes.Count) functional checks" -ForegroundColor Green
}
finally {
    $env:USERPROFILE=$oldProfile;$env:APPDATA=$oldAppData;$env:LOCALAPPDATA=$oldLocalAppData;$env:Path=$oldProcessPath
    if ($null -eq $oldTestDesktop) { Remove-Item Env:\CCDI_TEST_DESKTOP -ErrorAction SilentlyContinue } else { $env:CCDI_TEST_DESKTOP=$oldTestDesktop }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
