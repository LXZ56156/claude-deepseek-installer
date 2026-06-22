# ============================================================
# scripts/interactive-user-acceptance.ps1
# ConPTY-driven buyer terminal acceptance (TestSafe or guarded Live)
# ============================================================

[CmdletBinding()]
param(
    [ValidateSet("TestSafe", "Live")]
    [string]$Mode = "TestSafe",
    [string]$Version = "1.3.3",
    [string]$CredentialTarget = "CCDI_ACCEPTANCE_DEEPSEEK_API_KEY",
    [switch]$AcknowledgeRealInstall,
    [string]$SourceZip,
    [string]$RunRoot,
    [string[]]$ScenarioId,
    [switch]$SkipBuild,
    [switch]$SkipDriverSelfTest,
    [switch]$KeepExtracted
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$DriverSource = Join-Path $PSScriptRoot "lib\ConPtyAcceptanceHost.cs"
$ScenarioFile = Join-Path $PSScriptRoot "data\interactive-acceptance-scenarios.json"
$DummyApiKey = "sk-" + ("x" * 32)
$runId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
if (-not $RunRoot) {
    $RunRoot = Join-Path $ProjectRoot ".sandbox\interactive-acceptance\$runId"
}
$RunRoot = [System.IO.Path]::GetFullPath($RunRoot)
$EvidenceDir = Join-Path $RunRoot "evidence"
$ExtractRoot = Join-Path $RunRoot "买家 解压目录 With Spaces"
$TestProfile = Join-Path $RunRoot "测试用户 profile"
$TestDesktop = Join-Path $TestProfile "Desktop"
$ArtifactRoot = Join-Path $RunRoot "artifacts"

function Write-AcceptanceInfo {
    param([string]$Message)
    Write-Host "[interactive-acceptance] $Message" -ForegroundColor Cyan
}

function ConvertTo-WindowsCommandLineArgument {
    param([AllowNull()][string]$Argument)
    if ($null -eq $Argument -or $Argument.Length -eq 0) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $result = New-Object System.Text.StringBuilder
    [void]$result.Append('"')
    $backslashes = 0
    foreach ($char in $Argument.ToCharArray()) {
        if ($char -eq '\') { $backslashes++; continue }
        if ($char -eq '"') {
            [void]$result.Append(('\' * ($backslashes * 2 + 1)))
            [void]$result.Append('"')
        }
        else {
            if ($backslashes -gt 0) { [void]$result.Append(('\' * $backslashes)) }
            [void]$result.Append($char)
        }
        $backslashes = 0
    }
    if ($backslashes -gt 0) { [void]$result.Append(('\' * ($backslashes * 2))) }
    [void]$result.Append('"')
    return $result.ToString()
}

function ConvertTo-VisibleTerminalText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return "" }
    $value = $Text -replace "`0", ""
    $value = [regex]::Replace($value, "`e\][^`a]*(?:`a|`e\\)", "")
    $value = [regex]::Replace($value, "`e\[[0-?]*[ -/]*[@-~]", "")
    $value = $value -replace "`r(?!`n)", "`n"
    return $value
}

function Get-SettingsSnapshot {
    $path = Join-Path $env:USERPROFILE ".claude\settings.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [PSCustomObject]@{ Path = $path; Exists = $false; Length = 0; SHA256 = $null; Bytes = $null }
    }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    return [PSCustomObject]@{
        Path = $path
        Exists = $true
        Length = $bytes.Length
        SHA256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        Bytes = $bytes
    }
}

function Restore-SettingsSnapshot {
    param($Snapshot)
    if ($Snapshot.Exists) {
        $parent = Split-Path -Parent $Snapshot.Path
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [System.IO.File]::WriteAllBytes($Snapshot.Path, $Snapshot.Bytes)
    }
    elseif (Test-Path -LiteralPath $Snapshot.Path) {
        Remove-Item -LiteralPath $Snapshot.Path -Force
    }
}

function Assert-LivePreflight {
    if (-not $AcknowledgeRealInstall) {
        throw "Live mode requires -AcknowledgeRealInstall"
    }
    if (-not (Test-Path -LiteralPath "C:\CCDI-ACCEPTANCE-VM.marker" -PathType Leaf)) {
        throw "Live mode requires marker file C:\CCDI-ACCEPTANCE-VM.marker"
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Live mode requires an elevated administrator token"
    }
    $os = Get-CimInstance Win32_OperatingSystem
    if ([int]$os.BuildNumber -lt 22000) {
        throw "Live mode requires Windows 11 (build 22000 or newer); detected $($os.Caption) build $($os.BuildNumber)"
    }
    $system = Get-CimInstance Win32_ComputerSystem
    $vmText = "$($system.Manufacturer) $($system.Model)"
    if ($vmText -notmatch 'VMware') {
        throw "Live mode is restricted to VMware virtual machines; detected: $vmText"
    }
    $projectFull = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
    $currentFull = [IO.Path]::GetFullPath((Get-Location).Path).TrimEnd('\')
    $zipFull = if ($SourceZip) { [IO.Path]::GetFullPath($SourceZip) } else { $null }
    if (-not ($currentFull -eq $projectFull -or
        $currentFull.StartsWith($projectFull + '\', [StringComparison]::OrdinalIgnoreCase) -or
        ($zipFull -and (Test-Path -LiteralPath $zipFull -PathType Leaf)))) {
        throw "Live mode must run from this project or with an existing final acceptance ZIP"
    }
}

function Set-TemporaryEnvironment {
    param([hashtable]$Values)
    $saved = @{}
    foreach ($name in $Values.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        [Environment]::SetEnvironmentVariable($name, [string]$Values[$name], "Process")
    }
    return $saved
}

function Restore-TemporaryEnvironment {
    param([hashtable]$Saved)
    foreach ($name in $Saved.Keys) {
        [Environment]::SetEnvironmentVariable($name, $Saved[$name], "Process")
    }
}

function Stop-ConPtyTree {
    param($Process)
    if ($null -eq $Process) { return }
    try { $Process.Terminate(124) } catch { }
    if (-not $Process.JobAssigned -and $Process.ProcessId -gt 0) {
        try { & taskkill.exe /PID $Process.ProcessId /T /F 2>$null | Out-Null } catch { }
    }
}

function Add-InteractionEvent {
    param(
        [System.Collections.ArrayList]$Events,
        [string]$Type,
        [string]$Rule,
        [string]$Value
    )
    [void]$Events.Add([ordered]@{
        at = (Get-Date).ToString("o")
        type = $Type
        rule = $Rule
        value = $Value
    })
}

function Send-ScenarioInput {
    param(
        $Process,
        $Rule,
        [string]$Secret,
        [System.Collections.ArrayList]$Events
    )
    $properties = @($Rule.PSObject.Properties.Name)
    if ($properties -contains "delayMs" -and [int]$Rule.delayMs -gt 0) {
        Start-Sleep -Milliseconds ([int]$Rule.delayMs)
    }
    if ($properties -contains "sendSecret" -and $Rule.sendSecret) {
        if ([string]::IsNullOrEmpty($Secret)) { throw "Scenario requested a secret but none is available" }
        $Process.Write($Secret + "`r")
        Add-InteractionEvent -Events $Events -Type "send" -Rule ([string]$Rule.expect) -Value "[SECRET SENT]"
        return
    }
    if ($properties -contains "send" -and $null -ne $Rule.send) {
        $Process.Write([string]$Rule.send)
        $display = ([string]$Rule.send).Replace("`r", "<ENTER>").Replace("`n", "<LF>")
        if ([string]::IsNullOrEmpty($display)) { $display = "[EMPTY]" }
        Add-InteractionEvent -Events $Events -Type "send" -Rule ([string]$Rule.expect) -Value $display
    }
    else {
        Add-InteractionEvent -Events $Events -Type "observe" -Rule ([string]$Rule.expect) -Value "[NO INPUT]"
    }
}

function Invoke-ConPtyScenario {
    param(
        $Scenario,
        [string]$ReleaseRoot,
        [string]$Secret,
        [hashtable]$Environment,
        [string]$ScenarioEvidenceDir
    )

    New-Item -ItemType Directory -Path $ScenarioEvidenceDir -Force | Out-Null
    $scenarioReleaseRoot = $ReleaseRoot
    if ($Scenario.PSObject.Properties.Name -contains "isolatedCopy" -and $Scenario.isolatedCopy) {
        $scenarioReleaseRoot = Join-Path (Split-Path -Parent $ScenarioEvidenceDir) ("package-" + [string]$Scenario.id)
        Copy-Item -LiteralPath $ReleaseRoot -Destination $scenarioReleaseRoot -Recurse -Force
    }
    if ($Scenario.PSObject.Properties.Name -contains "removeBefore") {
        foreach ($relativePath in @($Scenario.removeBefore)) {
            $removePath = Join-Path $scenarioReleaseRoot ([string]$relativePath)
            if (Test-Path -LiteralPath $removePath) { Remove-Item -LiteralPath $removePath -Force -Recurse }
        }
    }
    $entryPath = Join-Path $scenarioReleaseRoot ([string]$Scenario.entry)
    if (-not (Test-Path -LiteralPath $entryPath -PathType Leaf)) { throw "Scenario entry missing: $entryPath" }

    $scenarioEnvironment = @{} + $Environment
    if ($Scenario.PSObject.Properties.Name -contains "environment") {
        foreach ($property in $Scenario.environment.PSObject.Properties) { $scenarioEnvironment[$property.Name] = [string]$property.Value }
    }
    $savedEnv = Set-TemporaryEnvironment -Values $scenarioEnvironment
    $process = $null
    $events = New-Object System.Collections.ArrayList
    $startedAt = Get-Date
    $scanOffset = 0
    $responderCounts = @{}
    $failurePatterns = @('脚本执行过程中发生未预期的错误', 'TIMEOUT:')

    try {
        $commandLine = (ConvertTo-WindowsCommandLineArgument $env:ComSpec) + " /d /s /c call " + (ConvertTo-WindowsCommandLineArgument $entryPath)
        $process = [Ccdi.Acceptance.ConPtyProcess]::Start($commandLine, $scenarioReleaseRoot, 160, 50)
        Add-InteractionEvent -Events $events -Type "start" -Rule ([string]$Scenario.id) -Value "PID=$($process.ProcessId); JobAssigned=$($process.JobAssigned)"
        $scenarioDeadline = $startedAt.AddSeconds([int]$Scenario.timeoutSec)

        $scenarioSteps = @($Scenario.steps)
        for ($stepIndex = 0; $stepIndex -lt $scenarioSteps.Count; $stepIndex++) {
            $step = $scenarioSteps[$stepIndex]
            $stateId = if ($step.PSObject.Properties.Name -contains "stateId") { [string]$step.stateId } else { "$($Scenario.id)-state-$($stepIndex + 1)" }
            $nextState = if ($step.PSObject.Properties.Name -contains "nextState") { [string]$step.nextState } elseif ($stepIndex + 1 -lt $scenarioSteps.Count) { "$($Scenario.id)-state-$($stepIndex + 2)" } else { "COMPLETE" }
            $stepTimeout = if ($step.PSObject.Properties.Name -contains "timeoutSec") { [int]$step.timeoutSec } else { 30 }
            $stepDeadline = (Get-Date).AddSeconds($stepTimeout)
            $matched = $false

            while (-not $matched) {
                if ((Get-Date) -gt $scenarioDeadline) { throw "Scenario total timeout waiting for: $($step.expect)" }
                if ((Get-Date) -gt $stepDeadline) { throw "Step timeout after ${stepTimeout}s waiting for: $($step.expect)" }

                $visible = ConvertTo-VisibleTerminalText -Text $process.GetOutput()
                if ($scanOffset -gt $visible.Length) { $scanOffset = 0 }
                $segment = $visible.Substring($scanOffset)

                foreach ($failurePattern in $failurePatterns) {
                    if ($segment -match $failurePattern) { throw "Failure text detected: $failurePattern" }
                }
                if ($step.PSObject.Properties.Name -contains "failureText") {
                    foreach ($failurePattern in @($step.failureText)) {
                        if ($segment -match [string]$failurePattern) { throw "State $stateId failure text detected: $failurePattern" }
                    }
                }

                $candidates = New-Object System.Collections.ArrayList
                $expectedMatch = [regex]::Match($segment, [string]$step.expect, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($expectedMatch.Success) {
                    [void]$candidates.Add([PSCustomObject]@{ Type = "step"; Rule = $step; Match = $expectedMatch })
                }

                $scenarioResponders = if ($Scenario.PSObject.Properties.Name -contains "responders") { @($Scenario.responders) } else { @() }
                foreach ($responder in $scenarioResponders) {
                    $key = [string]$responder.expect
                    $count = if ($responderCounts.ContainsKey($key)) { [int]$responderCounts[$key] } else { 0 }
                    $max = if ($responder.PSObject.Properties.Name -contains "maxMatches") { [int]$responder.maxMatches } else { 1 }
                    if ($count -ge $max) { continue }
                    $responderMatch = [regex]::Match($segment, $key, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                    if ($responderMatch.Success) {
                        [void]$candidates.Add([PSCustomObject]@{ Type = "responder"; Rule = $responder; Match = $responderMatch })
                    }
                }

                $candidate = $candidates | Sort-Object { $_.Match.Index } | Select-Object -First 1
                if ($candidate) {
                    $scanOffset += $candidate.Match.Index + $candidate.Match.Length
                    $matchValue = if ($candidate.Type -eq "step") { "state=$stateId; next=$nextState" } else { "responder" }
                    Add-InteractionEvent -Events $events -Type "match" -Rule ([string]$candidate.Rule.expect) -Value $matchValue
                    Send-ScenarioInput -Process $process -Rule $candidate.Rule -Secret $Secret -Events $events
                    if ($candidate.Type -eq "responder") {
                        $responderKey = [string]$candidate.Rule.expect
                        $responderCounts[$responderKey] = (if ($responderCounts.ContainsKey($responderKey)) { [int]$responderCounts[$responderKey] + 1 } else { 1 })
                    }
                    else {
                        $matched = $true
                    }
                    continue
                }

                if ($process.HasExited) {
                    throw "Process exited before expected prompt: $($step.expect); exit=$($process.ExitCode)"
                }
                Start-Sleep -Milliseconds 50
            }
        }

        if (-not $process.WaitForExit(30000)) {
            throw "Process did not exit within 30 seconds after the final interaction"
        }
        $exitCode = $process.ExitCode
        if (@($Scenario.expectedExitCodes) -notcontains $exitCode) {
            throw "Unexpected exit code $exitCode; expected $(@($Scenario.expectedExitCodes) -join ', ')"
        }

        $visibleOutput = ConvertTo-VisibleTerminalText -Text $process.GetOutput()
        foreach ($required in @($Scenario.required)) {
            if ($visibleOutput -notmatch [regex]::Escape([string]$required)) { throw "Required output missing: $required" }
        }
        $scenarioForbidden = if ($Scenario.PSObject.Properties.Name -contains "forbidden") { @($Scenario.forbidden) } else { @() }
        foreach ($forbidden in $scenarioForbidden) {
            if ($visibleOutput -match [regex]::Escape([string]$forbidden)) { throw "Forbidden output found: $forbidden" }
        }
        if ($process.OutputError) { throw "ConPTY output reader failed: $($process.OutputError)" }

        $safeOutput = if ($Secret) { $visibleOutput.Replace($Secret, "[REDACTED]") } else { $visibleOutput }
        [System.IO.File]::WriteAllText((Join-Path $ScenarioEvidenceDir "transcript.txt"), $safeOutput, (New-Object Text.UTF8Encoding($false)))
        $events | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ScenarioEvidenceDir "events.json") -Encoding UTF8

        return [PSCustomObject]@{
            Id = [string]$Scenario.id
            Status = "PASS"
            ExitCode = $exitCode
            DurationSec = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 2)
            Evidence = $ScenarioEvidenceDir
            Error = $null
        }
    }
    catch {
        Stop-ConPtyTree -Process $process
        $raw = if ($process) { ConvertTo-VisibleTerminalText -Text $process.GetOutput() } else { "" }
        $safe = if ($Secret) { $raw.Replace($Secret, "[REDACTED]") } else { $raw }
        [System.IO.File]::WriteAllText((Join-Path $ScenarioEvidenceDir "transcript.txt"), $safe, (New-Object Text.UTF8Encoding($false)))
        $events | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ScenarioEvidenceDir "events.json") -Encoding UTF8
        return [PSCustomObject]@{
            Id = [string]$Scenario.id
            Status = "FAIL"
            ExitCode = if ($process -and $process.HasExited) { $process.ExitCode } else { $null }
            DurationSec = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 2)
            Evidence = $ScenarioEvidenceDir
            Error = $_.Exception.Message
        }
    }
    finally {
        if ($process) { $process.Dispose() }
        Restore-TemporaryEnvironment -Saved $savedEnv
    }
}

function Invoke-DriverSelfTest {
    param([string]$Directory)
    $selfTestDir = Join-Path $Directory "driver-self-test"
    New-Item -ItemType Directory -Path $selfTestDir -Force | Out-Null
    $helper = Join-Path $selfTestDir "self-test.ps1"
    $launcher = Join-Path $selfTestDir "self-test.cmd"
    $helperText = @'
$host.UI.RawUI.WindowTitle = "CCDI ConPTY self-test"
Write-Host -NoNewline "分段提"
Start-Sleep -Milliseconds 150
Write-Host -NoNewline "示>"
$value = Read-Host
Write-Host "VALUE=$value"
$secret = Read-Host -AsSecureString "SECRET"
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
try { $length = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr).Length }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
Write-Host "SECRET_LENGTH=$length"
Write-Host "`e[32mANSI_OK`e[0m"
Write-Host -NoNewline "CR_OLD`rCR_NEW"
Write-Host ""
Write-Host "Press any key to close this window..."
cmd.exe /d /c pause `>nul
'@
    Set-Content -LiteralPath $helper -Value $helperText -Encoding UTF8
    "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0self-test.ps1`"`r`n" | Set-Content -LiteralPath $launcher -Encoding ASCII
    $scenario = [PSCustomObject]@{
        id = "driver-self-test"
        entry = "self-test.cmd"
        timeoutSec = 30
        responders = @()
        steps = @(
            [PSCustomObject]@{ expect = "分段提示>"; send = "Y`r"; timeoutSec = 5 },
            [PSCustomObject]@{ expect = "SECRET"; sendSecret = "dummy"; timeoutSec = 5 },
            [PSCustomObject]@{ expect = "Press any key to close this window"; send = " `r"; delayMs = 300; timeoutSec = 5 }
        )
        required = @("VALUE=Y", "SECRET_LENGTH=35", "ANSI_OK", "CR_NEW")
        forbidden = @($DummyApiKey)
        expectedExitCodes = @(0)
    }
    $result = Invoke-ConPtyScenario -Scenario $scenario -ReleaseRoot $selfTestDir -Secret $DummyApiKey -Environment @{} -ScenarioEvidenceDir (Join-Path $EvidenceDir "driver-self-test")
    if ($result.Status -ne "PASS") { throw "ConPTY driver self-test failed: $($result.Error)" }

    $driverEvents = Get-Content -LiteralPath (Join-Path $EvidenceDir "driver-self-test\events.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $startEvent = @($driverEvents | Where-Object type -eq "start" | Select-Object -First 1)
    if (-not $startEvent -or [string]$startEvent.value -notmatch 'JobAssigned=True') {
        throw "ConPTY driver self-test did not assign the process to a kill-on-close Job Object"
    }

    $failureDir = Join-Path $selfTestDir "failure-path"
    New-Item -ItemType Directory -Path $failureDir -Force | Out-Null
    $failureHelper = Join-Path $failureDir "failure-test.ps1"
    $failureLauncher = Join-Path $failureDir "failure-test.cmd"
    $childPidPath = Join-Path $failureDir "child.pid"
    @'
$child = Start-Process powershell.exe -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 120' -PassThru -WindowStyle Hidden
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'child.pid') -Value $child.Id -Encoding ASCII
Write-Host -NoNewline '重复提示>'
[void](Read-Host)
Write-Host -NoNewline '重复提示>'
[void](Read-Host)
'@ | Set-Content -LiteralPath $failureHelper -Encoding UTF8
    "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0failure-test.ps1`"`r`n" | Set-Content -LiteralPath $failureLauncher -Encoding ASCII
    $failureScenario = [PSCustomObject]@{
        id = "driver-failure-self-test"
        entry = "failure-test.cmd"
        timeoutSec = 8
        responders = @()
        steps = @(
            [PSCustomObject]@{ stateId = "first-prompt"; expect = "重复提示>"; send = "Y`r"; nextState = "must-not-repeat"; timeoutSec = 3 },
            [PSCustomObject]@{ stateId = "must-not-repeat"; expect = "THIS_PROMPT_MUST_NOT_EXIST"; send = $null; nextState = "COMPLETE"; failureText = @("UNEXPECTED_FATAL_TEXT"); timeoutSec = 2 }
        )
        required = @()
        forbidden = @($DummyApiKey)
        expectedExitCodes = @(0)
    }
    $failureResult = Invoke-ConPtyScenario -Scenario $failureScenario -ReleaseRoot $failureDir -Secret $DummyApiKey -Environment @{} -ScenarioEvidenceDir (Join-Path $EvidenceDir "driver-failure-self-test")
    if ($failureResult.Status -ne "FAIL" -or $failureResult.Error -notmatch 'Step timeout') {
        throw "Unknown or repeated prompt self-test must fail by state timeout"
    }
    if (-not (Test-Path -LiteralPath $childPidPath -PathType Leaf)) { throw "Process-tree cleanup self-test did not create a child PID" }
    $childPid = [int](Get-Content -LiteralPath $childPidPath -Raw)
    for ($attempt = 0; $attempt -lt 20 -and (Get-Process -Id $childPid -ErrorAction SilentlyContinue); $attempt++) {
        Start-Sleep -Milliseconds 100
    }
    if (Get-Process -Id $childPid -ErrorAction SilentlyContinue) {
        try { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue } catch { }
        throw "ConPTY timeout did not terminate the child process tree: PID=$childPid"
    }
}

function Assert-NoSecretInEvidence {
    param([string]$Secret)
    if ([string]::IsNullOrEmpty($Secret)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $EvidenceDir -File -Recurse -ErrorAction SilentlyContinue) {
        $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
        if ($text -and $text.Contains($Secret)) { throw "Secret leaked into evidence: $($file.FullName)" }
    }
}

if (-not (Test-Path -LiteralPath $DriverSource -PathType Leaf)) { throw "ConPTY driver source missing: $DriverSource" }
if (-not (Test-Path -LiteralPath $ScenarioFile -PathType Leaf)) { throw "Scenario definition missing: $ScenarioFile" }
New-Item -ItemType Directory -Path $EvidenceDir, $TestDesktop, $ArtifactRoot -Force | Out-Null

Write-AcceptanceInfo "Mode=$Mode RunRoot=$RunRoot"
Add-Type -Path $DriverSource

$realSettingsBefore = Get-SettingsSnapshot
$realSettingsAfter = $null
$secret = if ($Mode -eq "TestSafe") { $DummyApiKey } else { $null }
$results = New-Object System.Collections.ArrayList
$success = $false
$failureMessage = $null

try {
    if ($Mode -eq "Live") {
        Assert-LivePreflight
    }

    if (-not $SkipDriverSelfTest) {
        Write-AcceptanceInfo "Running ConPTY driver self-test"
        Invoke-DriverSelfTest -Directory $RunRoot
    }

    if (-not $SourceZip) {
        $SourceZip = Join-Path $ProjectRoot "release\ClaudeCode-DeepSeek-本地配置助手-v$Version.zip"
    }
    if (-not $SkipBuild) {
        Write-AcceptanceInfo "Building release ZIP"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "build-release.ps1") -Version $Version
        if ($LASTEXITCODE -ne 0) { throw "build-release.ps1 failed with exit code $LASTEXITCODE" }
    }
    if (-not (Test-Path -LiteralPath $SourceZip -PathType Leaf)) { throw "Release ZIP not found: $SourceZip" }

    Write-AcceptanceInfo "Extracting release ZIP to $ExtractRoot"
    Expand-Archive -LiteralPath $SourceZip -DestinationPath $ExtractRoot -Force

    $scenarioDocument = Get-Content -LiteralPath $ScenarioFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$scenarioDocument.schemaVersion -ne 1) { throw "Unsupported scenario schema version: $($scenarioDocument.schemaVersion)" }
    $scenarios = @($scenarioDocument.scenarioSets.$Mode)
    if ($ScenarioId -and $ScenarioId.Count -gt 0) {
        $scenarios = @($scenarios | Where-Object { [string]$_.id -in $ScenarioId })
        $missingScenarioIds = @($ScenarioId | Where-Object { $_ -notin @($scenarios.id) })
        if ($missingScenarioIds.Count -gt 0) { throw "Unknown scenario id(s): $($missingScenarioIds -join ', ')" }
    }
    if ($scenarios.Count -eq 0) { throw "No scenarios defined for mode $Mode" }
    $requiresRealCredential = $Mode -eq "Live" -and @($scenarios | ForEach-Object { @($_.steps) } | Where-Object {
        $_.PSObject.Properties.Name -contains "sendSecret" -and $_.sendSecret -eq "credential"
    }).Count -gt 0
    if ($requiresRealCredential) {
        $secret = [Ccdi.Acceptance.WindowsCredential]::ReadGeneric($CredentialTarget)
        if ([string]::IsNullOrWhiteSpace($secret) -or $secret -notmatch '^sk-.{20,}$') {
            throw "Credential $CredentialTarget does not contain a plausible DeepSeek API Key"
        }
    }

    $environment = @{
        CCDI_NO_INTERACTIVE_UI = "1"
        NO_COLOR = "1"
        TERM = "xterm-256color"
    }
    if ($Mode -eq "TestSafe") {
        $environment.CCDI_TEST_MODE = "1"
        $environment.CCDI_TEST_USERPROFILE = $TestProfile
        $environment.CCDI_TEST_DESKTOP = $TestDesktop
        $environment.CCDI_TEST_ARTIFACT_ROOT = $ArtifactRoot
        $environment.CCDI_TEST_API_STATUS = "200"
    }
    else {
        $environment.CCDI_ACCEPTANCE_VM = "1"
    }

    foreach ($scenario in $scenarios) {
        Write-AcceptanceInfo "Scenario: $($scenario.id)"
        if ($scenario.PSObject.Properties.Name -contains "setupDummyConfig" -and $scenario.setupDummyConfig) {
            $dummyProfile = if ($Mode -eq "TestSafe") { $TestProfile } else { $env:USERPROFILE }
            $dummyConfigDir = Join-Path $dummyProfile ".claude"
            New-Item -ItemType Directory -Path $dummyConfigDir -Force | Out-Null
            $dummyConfig = [ordered]@{ env = [ordered]@{ ANTHROPIC_AUTH_TOKEN = $DummyApiKey; ANTHROPIC_BASE_URL = "https://api.deepseek.com/anthropic" } }
            $dummyConfig | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dummyConfigDir "settings.json") -Encoding UTF8
        }
        $scenarioDir = Join-Path $EvidenceDir ([string]$scenario.id)
        $result = Invoke-ConPtyScenario -Scenario $scenario -ReleaseRoot $ExtractRoot -Secret $secret -Environment $environment -ScenarioEvidenceDir $scenarioDir
        [void]$results.Add($result)
        Write-AcceptanceInfo "$($result.Id): $($result.Status) ($($result.DurationSec)s)"
        if ($result.Status -ne "PASS" -and $Mode -eq "Live") { break }
    }

    $failed = @($results | Where-Object { $_.Status -ne "PASS" })
    if ($failed.Count -gt 0) {
        throw (($failed | ForEach-Object { "$($_.Id): $($_.Error)" }) -join "; ")
    }

    Assert-NoSecretInEvidence -Secret $secret
    $success = $true
}
catch {
    $failureMessage = $_.Exception.Message
}
finally {
    if ($Mode -eq "Live") {
        try { Restore-SettingsSnapshot -Snapshot $realSettingsBefore }
        catch {
            $success = $false
            $restoreError = "Failed to restore settings.json: $($_.Exception.Message)"
            $failureMessage = if ($failureMessage) { "$failureMessage; $restoreError" } else { $restoreError }
        }
    }
    try {
        $realSettingsAfter = Get-SettingsSnapshot
        if ($realSettingsBefore.Exists -ne $realSettingsAfter.Exists -or
            $realSettingsBefore.Length -ne $realSettingsAfter.Length -or
            $realSettingsBefore.SHA256 -ne $realSettingsAfter.SHA256) {
            throw "settings.json differs after acceptance cleanup"
        }
    }
    catch {
        $success = $false
        $settingsError = "settings.json final comparison failed: $($_.Exception.Message)"
        $failureMessage = if ($failureMessage) { "$failureMessage; $settingsError" } else { $settingsError }
    }
    if ($realSettingsBefore.Bytes) { [Array]::Clear($realSettingsBefore.Bytes, 0, $realSettingsBefore.Bytes.Length) }
    if ($realSettingsAfter -and $realSettingsAfter.Bytes) { [Array]::Clear($realSettingsAfter.Bytes, 0, $realSettingsAfter.Bytes.Length) }
}

$summary = [ordered]@{
    schemaVersion = 1
    runId = $runId
    mode = $Mode
    version = $Version
    status = if ($success) { "PASS" } else { "FAIL" }
    startedFrom = $ProjectRoot
    zip = if ($SourceZip) { [System.IO.Path]::GetFullPath($SourceZip) } else { $null }
    zipSha256 = if ($SourceZip -and (Test-Path -LiteralPath $SourceZip)) { (Get-FileHash -LiteralPath $SourceZip -Algorithm SHA256).Hash } else { $null }
    settingsBefore = [ordered]@{ Exists = $realSettingsBefore.Exists; Length = $realSettingsBefore.Length; SHA256 = $realSettingsBefore.SHA256 }
    settingsAfter = if ($realSettingsAfter) { [ordered]@{ Exists = $realSettingsAfter.Exists; Length = $realSettingsAfter.Length; SHA256 = $realSettingsAfter.SHA256 } } else { $null }
    scenarios = @($results | ForEach-Object {
        [ordered]@{ id = $_.Id; status = $_.Status; exitCode = $_.ExitCode; durationSec = $_.DurationSec; evidence = $_.Evidence; error = $_.Error }
    })
    error = $failureMessage
    completedAt = (Get-Date).ToString("o")
}
$summaryJson = Join-Path $EvidenceDir "summary.json"
$summaryText = Join-Path $EvidenceDir "summary.txt"
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryJson -Encoding UTF8
$textLines = @(
    "CCDI interactive acceptance",
    "Status: $($summary.status)",
    "Mode: $Mode",
    "Version: $Version",
    "ZIP SHA256: $($summary.zipSha256)",
    "Scenarios: $(@($results | Where-Object Status -eq 'PASS').Count) passed, $(@($results | Where-Object Status -ne 'PASS').Count) failed",
    "Evidence: $EvidenceDir"
)
if ($failureMessage) { $textLines += "Error: $failureMessage" }
$textLines | Set-Content -LiteralPath $summaryText -Encoding UTF8

if ($success -and -not $KeepExtracted) {
    Remove-Item -LiteralPath $ExtractRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-AcceptanceInfo "Summary: $summaryText"
if (-not $success) {
    Write-Host "[interactive-acceptance] FAIL: $failureMessage" -ForegroundColor Red
    exit 1
}
Write-Host "[interactive-acceptance] PASS" -ForegroundColor Green
exit 0
