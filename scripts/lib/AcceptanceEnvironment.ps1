# Single-user environment baseline and exact rollback helpers for VM acceptance.

Set-StrictMode -Version Latest

function ConvertTo-AcceptanceNativeArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value -notmatch '[\s"]' -and $Value.Length -gt 0) { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-AcceptanceCapturedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [ValidateRange(1, 300)][int]$TimeoutSec = 15
    )

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $nativeArguments = (@($ArgumentList) | ForEach-Object { ConvertTo-AcceptanceNativeArgument ([string]$_) }) -join ' '
    $extension = [IO.Path]::GetExtension($FilePath)
    if ($extension -match '^\.(cmd|bat)$') {
        $startInfo.FileName = $env:ComSpec
        $startInfo.Arguments = '/d /s /c ""' + $FilePath.Replace('"', '""') + '" ' + $nativeArguments + '"'
    }
    elseif ($extension -ieq '.ps1') {
        $startInfo.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (ConvertTo-AcceptanceNativeArgument $FilePath) + ' ' + $nativeArguments
    }
    else {
        $startInfo.FileName = $FilePath
        $startInfo.Arguments = $nativeArguments
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Process failed to start." }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            & taskkill.exe /PID $process.Id /T /F 2>$null | Out-Null
            [void]$process.WaitForExit(5000)
            return [ordered]@{ ExitCode = $null; TimedOut = $true; StdOut = ''; StdErr = '' }
        }
        $process.WaitForExit()
        return [ordered]@{
            ExitCode = $process.ExitCode
            TimedOut = $false
            StdOut = [string]$stdoutTask.Result
            StdErr = [string]$stderrTask.Result
        }
    }
    catch {
        return [ordered]@{ ExitCode = $null; TimedOut = $false; StdOut = ''; StdErr = [string]$_.Exception.Message }
    }
    finally { $process.Dispose() }
}

function Get-AcceptanceControlPaths {
    param([string]$ControlRoot = "C:\CCDI-Acceptance-Control", [string]$RunId)
    if (-not $RunId) { $RunId = Get-Date -Format "yyyyMMdd-HHmmss-fff" }
    [PSCustomObject]@{
        Root = [IO.Path]::GetFullPath($ControlRoot)
        Baseline = [IO.Path]::GetFullPath((Join-Path $ControlRoot "baseline"))
        Runs = [IO.Path]::GetFullPath((Join-Path $ControlRoot "runs"))
        Run = [IO.Path]::GetFullPath((Join-Path $ControlRoot "runs\$RunId"))
        ResumeState = [IO.Path]::GetFullPath((Join-Path $ControlRoot "resume-state.json"))
        ResumeTask = "CCDI-Acceptance-Resume"
        ResumeUserTask = "CCDI-Acceptance-Resume-User"
    }
}

function Get-AcceptanceFileState {
    param([string[]]$Roots)
    $result = New-Object System.Collections.ArrayList
    foreach ($root in @($Roots | Where-Object { $_ } | Select-Object -Unique)) {
        $fullRoot = [IO.Path]::GetFullPath($root)
        $exists = Test-Path -LiteralPath $fullRoot
        [void]$result.Add([ordered]@{ Path = $fullRoot; Type = "Root"; Exists = $exists; Length = 0; SHA256 = $null })
        if (-not $exists) { continue }
        foreach ($item in Get-ChildItem -LiteralPath $fullRoot -Force -Recurse -ErrorAction SilentlyContinue) {
            if ($item.FullName -match '\\.codex(?:\\|$)') { continue }
            if ($item.FullName -match '\\.claude\\_git_cache\.json$') { continue }
            if ($item.PSIsContainer) {
                [void]$result.Add([ordered]@{ Path = $item.FullName; Type = "Directory"; Exists = $true; Length = 0; SHA256 = $null })
            }
            else {
                $hash = try { (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $null }
                [void]$result.Add([ordered]@{ Path = $item.FullName; Type = "File"; Exists = $true; Length = $item.Length; SHA256 = $hash })
            }
        }
    }
    return @($result | Sort-Object Path)
}

function Get-AcceptanceCommandState {
    param([string]$Name)
    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { return [ordered]@{ Name = $Name; Exists = $false; Version = $null; Source = $null; Path = $null } }
    $version = $null
    if ($Name -eq 'claude' -and [IO.Path]::GetExtension([string]$command.Source) -ieq '.exe') {
        $version = try { [string](Get-Item -LiteralPath ([string]$command.Source) -ErrorAction Stop).VersionInfo.ProductVersion } catch { '__ERROR__' }
    }
    else {
        $probe = Invoke-AcceptanceCapturedCommand -FilePath ([string]$command.Source) -ArgumentList @('--version') -TimeoutSec 10
        if ($probe.TimedOut) { $version = '__TIMEOUT__' }
        elseif ($null -eq $probe.ExitCode) { $version = '__ERROR__' }
        else {
            $output = @(([string]$probe.StdOut -split "`r?`n") + ([string]$probe.StdErr -split "`r?`n")) |
                Where-Object { $_ } | Select-Object -First 1
            if ($output) { $version = [string]$output }
        }
    }
    return [ordered]@{ Name = $Name; Exists = $true; Version = $version; Source = [string]$command.Source; Path = [string]$command.Path }
}

function Get-AcceptanceNpmPackages {
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $npm) { return @() }
    try {
        $probe = Invoke-AcceptanceCapturedCommand -FilePath ([string]$npm.Source) -ArgumentList @('ls', '-g', '--depth=0', '--json') -TimeoutSec 20
        if ($probe.TimedOut) { return @([ordered]@{ Id = '__UNAVAILABLE__'; Version = 'timeout' }) }
        if ($null -eq $probe.ExitCode) { return @([ordered]@{ Id = '__UNAVAILABLE__'; Version = 'start-error' }) }
        $json = [string]$probe.StdOut
        $data = $json | ConvertFrom-Json
        return @($data.dependencies.PSObject.Properties | ForEach-Object {
            [ordered]@{ Id = $_.Name; Version = [string]$_.Value.version }
        } | Sort-Object Id)
    }
    catch { return @([ordered]@{ Id = '__UNAVAILABLE__'; Version = 'invalid-output' }) }
}

function Get-AcceptanceWingetPackages {
    param([string]$TempRoot)
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) { return @() }
    $export = Join-Path $TempRoot ("winget-" + [guid]::NewGuid().ToString("N") + ".json")
    try {
        $probe = Invoke-AcceptanceCapturedCommand -FilePath ([string]$winget.Source) -ArgumentList @(
            'export', '--output', $export, '--include-versions', '--accept-source-agreements', '--disable-interactivity'
        ) -TimeoutSec 45
        if ($probe.TimedOut) { return @([ordered]@{ Id = '__UNAVAILABLE__'; Version = 'timeout' }) }
        if ($null -eq $probe.ExitCode) { return @([ordered]@{ Id = '__UNAVAILABLE__'; Version = 'start-error' }) }
        if (-not (Test-Path -LiteralPath $export)) { return @([ordered]@{ Id = '__UNAVAILABLE__'; Version = 'no-export' }) }
        $data = Get-Content -LiteralPath $export -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($data.Sources.Packages | ForEach-Object {
            [ordered]@{ Id = [string]$_.PackageIdentifier; Version = [string]$_.Version }
        } | Sort-Object Id)
    }
    catch { return @([ordered]@{ Id = '__UNAVAILABLE__'; Version = 'invalid-output' }) }
    finally { Remove-Item -LiteralPath $export -Force -ErrorAction SilentlyContinue }
}

function Get-AcceptanceRegistryState {
    $targets = @(
        @{ Path = "HKCU:\Environment"; Names = @("Path") },
        @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"; Names = @("Path") },
        @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\claude.exe"; Names = @("(default)", "Path") },
        @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\node.exe"; Names = @("(default)", "Path") }
    )
    $result = New-Object System.Collections.ArrayList
    foreach ($target in $targets) {
        foreach ($name in $target.Names) {
            $exists = Test-Path -LiteralPath $target.Path
            $value = $null
            $hasValue = $false
            if ($exists) {
                try {
                    $propertyName = if ($name -eq "(default)") { "" } else { $name }
                    $value = (Get-ItemPropertyValue -LiteralPath $target.Path -Name $propertyName -ErrorAction Stop)
                    $hasValue = $true
                }
                catch { }
            }
            [void]$result.Add([ordered]@{ Path = $target.Path; Name = $name; KeyExists = $exists; ValueExists = $hasValue; Value = $value })
        }
    }
    return @($result)
}

function Get-AcceptanceRelevantProcesses {
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^(claude|node|npm|winget)(\.exe)?$' -or
        $_.CommandLine -match 'ClaudeCode|Anthropic|nodejs|@anthropic-ai'
    } | ForEach-Object {
        [ordered]@{ ProcessId = $_.ProcessId; ParentProcessId = $_.ParentProcessId; Name = $_.Name; ExecutablePath = $_.ExecutablePath; CommandLine = $_.CommandLine }
    } | Sort-Object ProcessId)
}

function Get-AcceptanceRelevantServices {
    @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match 'claude|anthropic|node|npm' -or $_.PathName -match 'claude|anthropic|nodejs|npm'
    } | ForEach-Object { [ordered]@{ Name = $_.Name; State = $_.State; StartMode = $_.StartMode; PathName = $_.PathName } } | Sort-Object Name)
}

function Get-AcceptanceRelevantTasks {
    @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -match 'claude|anthropic|node|npm|CCDI-Acceptance' -or $_.TaskPath -match 'claude|anthropic|node|npm|CCDI-Acceptance'
    } | ForEach-Object { [ordered]@{ TaskName = $_.TaskName; TaskPath = $_.TaskPath; State = [string]$_.State } } | Sort-Object TaskPath, TaskName)
}

function Get-AcceptanceKnownRoots {
    param([string[]]$AdditionalRoots)
    $roots = @(
        (Join-Path $env:USERPROFILE ".claude"),
        (Join-Path $env:USERPROFILE ".local\bin"),
        (Join-Path $env:USERPROFILE ".local\share\claude"),
        (Join-Path $env:APPDATA "npm"),
        (Join-Path $env:LOCALAPPDATA "Programs\claude"),
        (Join-Path $env:LOCALAPPDATA "AnthropicClaude"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\claude.exe"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\claude.cmd"),
        (Join-Path $env:ProgramFiles "nodejs")
    ) + @($AdditionalRoots)
    @($roots | Where-Object { $_ -and ([IO.Path]::GetFullPath($_) -notmatch '\\.codex(?:\\|$)') } | Select-Object -Unique)
}

function Get-AcceptanceEnvironmentSnapshot {
    param(
        [string]$ProjectRoot,
        [string]$TempRoot,
        [string[]]$AdditionalRoots = @()
    )
    if (-not (Test-Path -LiteralPath $TempRoot)) { New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null }
    $settingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
    $settingsExists = Test-Path -LiteralPath $settingsPath -PathType Leaf
    $settingsItem = if ($settingsExists) { Get-Item -LiteralPath $settingsPath } else { $null }
    $head = try { (& git -C $ProjectRoot rev-parse HEAD 2>$null | Select-Object -First 1) } catch { $null }
    [ordered]@{
        SchemaVersion = 1
        CapturedAt = (Get-Date).ToString("o")
        Computer = $env:COMPUTERNAME
        User = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        WindowsBuild = [Environment]::OSVersion.Version.ToString()
        PowerShell = $PSVersionTable.PSVersion.ToString()
        FullSHA = $head
        Settings = [ordered]@{
            Path = $settingsPath
            Exists = $settingsExists
            Length = if ($settingsExists) { $settingsItem.Length } else { 0 }
            SHA256 = if ($settingsExists) { (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash } else { $null }
        }
        UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
        MachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        Commands = @("claude", "node", "npm", "winget") | ForEach-Object { Get-AcceptanceCommandState $_ }
        NpmGlobal = @(Get-AcceptanceNpmPackages)
        Winget = @(Get-AcceptanceWingetPackages -TempRoot $TempRoot)
        Registry = @(Get-AcceptanceRegistryState)
        Files = @(Get-AcceptanceFileState -Roots (Get-AcceptanceKnownRoots -AdditionalRoots $AdditionalRoots))
        Processes = @(Get-AcceptanceRelevantProcesses)
        Services = @(Get-AcceptanceRelevantServices)
        ScheduledTasks = @(Get-AcceptanceRelevantTasks)
    }
}

function Compare-AcceptanceSnapshot {
    param($Before, $After)
    $beforeFiles = @{}; foreach ($item in @($Before.Files)) { $beforeFiles[[string]$item.Path] = $item }
    $afterFiles = @{}; foreach ($item in @($After.Files)) { $afterFiles[[string]$item.Path] = $item }
    $created = @($afterFiles.Keys | Where-Object {
        -not $beforeFiles.ContainsKey($_) -or (-not [bool]$beforeFiles[$_].Exists -and [bool]$afterFiles[$_].Exists)
    } | Sort-Object)
    $removed = @($beforeFiles.Keys | Where-Object {
        -not $afterFiles.ContainsKey($_) -or ([bool]$beforeFiles[$_].Exists -and -not [bool]$afterFiles[$_].Exists)
    } | Sort-Object)
    $modified = @($beforeFiles.Keys | Where-Object {
        $afterFiles.ContainsKey($_) -and [bool]$beforeFiles[$_].Exists -and [bool]$afterFiles[$_].Exists -and
        (($beforeFiles[$_] | ConvertTo-Json -Compress) -ne ($afterFiles[$_] | ConvertTo-Json -Compress))
    } | Sort-Object)

    $beforeNpm = @{}; foreach ($item in @($Before.NpmGlobal)) { $beforeNpm[[string]$item.Id] = [string]$item.Version }
    $afterNpm = @{}; foreach ($item in @($After.NpmGlobal)) { $afterNpm[[string]$item.Id] = [string]$item.Version }
    $beforeWinget = @{}; foreach ($item in @($Before.Winget)) { $beforeWinget[[string]$item.Id] = [string]$item.Version }
    $afterWinget = @{}; foreach ($item in @($After.Winget)) { $afterWinget[[string]$item.Id] = [string]$item.Version }

    [ordered]@{
        CreatedPaths = $created
        RemovedPaths = $removed
        ModifiedPaths = $modified
        NewNpmPackages = @($afterNpm.Keys | Where-Object { $_ -notmatch '^__' -and -not $beforeNpm.ContainsKey($_) } | Sort-Object)
        NewWingetPackages = @($afterWinget.Keys | Where-Object { $_ -notmatch '^__' -and -not $beforeWinget.ContainsKey($_) } | Sort-Object)
        UserPathChanged = $Before.UserPath -ne $After.UserPath
        MachinePathChanged = $Before.MachinePath -ne $After.MachinePath
        RegistryChanged = (($Before.Registry | ConvertTo-Json -Depth 8 -Compress) -ne ($After.Registry | ConvertTo-Json -Depth 8 -Compress))
        SettingsChanged = (($Before.Settings | ConvertTo-Json -Compress) -ne ($After.Settings | ConvertTo-Json -Compress))
        NewProcesses = @($After.Processes | Where-Object { $_.ProcessId -notin @($Before.Processes.ProcessId) })
        NewServices = @($After.Services | Where-Object { $_.Name -notin @($Before.Services.Name) })
        NewScheduledTasks = @($After.ScheduledTasks | Where-Object { "$($_.TaskPath)$($_.TaskName)" -notin @($Before.ScheduledTasks | ForEach-Object { "$($_.TaskPath)$($_.TaskName)" }) })
    }
}

function Test-AcceptanceProtectedPath {
    param([string]$Path, [string]$ProjectRoot, [string]$ControlRoot, [string]$ResultRoot)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $protected = @(
        [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\'),
        [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE ".codex")).TrimEnd('\'),
        [IO.Path]::GetFullPath($ControlRoot).TrimEnd('\'),
        [IO.Path]::GetFullPath($ResultRoot).TrimEnd('\'),
        [Environment]::GetFolderPath("Windows").TrimEnd('\'),
        [Environment]::GetFolderPath("System").TrimEnd('\')
    )
    foreach ($root in $protected) {
        if ($full -eq $root -or $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Restore-AcceptanceSettings {
    param($Baseline, [byte[]]$SettingsBytes)
    $path = [string]$Baseline.Settings.Path
    if ($Baseline.Settings.Exists) {
        $parent = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [IO.File]::WriteAllBytes($path, $SettingsBytes)
    }
    elseif (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Restore-AcceptanceRegistry {
    param($BaselineRegistry)
    foreach ($entry in @($BaselineRegistry)) {
        $path = [string]$entry.Path
        $name = if ([string]$entry.Name -eq "(default)") { "" } else { [string]$entry.Name }
        if ($entry.KeyExists -and -not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
        if ($entry.ValueExists) {
            Set-ItemProperty -LiteralPath $path -Name $name -Value $entry.Value -Force
        }
        elseif (Test-Path -LiteralPath $path) {
            Remove-ItemProperty -LiteralPath $path -Name $name -Force -ErrorAction SilentlyContinue
            if (-not $entry.KeyExists -and $path -match 'App Paths\\(claude|node)\.exe$') {
                $remaining = @(Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue).PSObject.Properties |
                    Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' }
                if (@($remaining).Count -eq 0) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}

function Reset-AcceptanceEnvironment {
    param(
        $Baseline,
        $Current,
        $Delta,
        [byte[]]$SettingsBytes,
        [string]$ProjectRoot,
        [string]$ControlRoot,
        [string]$ResultRoot,
        [string[]]$AllowedCleanupRoots,
        [int[]]$ProtectedProcessIds
    )
    $actions = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList

    foreach ($process in @($Delta.NewProcesses)) {
        if ($process.ProcessId -in $ProtectedProcessIds) { continue }
        if ($process.Name -notmatch 'claude|node|npm|winget' -and $process.CommandLine -notmatch 'ClaudeCode|Anthropic|nodejs|@anthropic-ai') { continue }
        try { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop; [void]$actions.Add("Stopped process $($process.ProcessId) $($process.Name)") }
        catch { [void]$errors.Add("Failed to stop process $($process.ProcessId): $($_.Exception.Message)") }
    }

    foreach ($package in @($Delta.NewNpmPackages | Where-Object { $_ -and $_ -notmatch '^__' })) {
        try {
            $npmCommand = Get-Command npm.cmd -ErrorAction Stop | Select-Object -First 1
            $probe = Invoke-AcceptanceCapturedCommand -FilePath ([string]$npmCommand.Source) -ArgumentList @('uninstall', '-g', $package) -TimeoutSec 180
            if ($probe.TimedOut -or $probe.ExitCode -ne 0) { throw $(if ($probe.TimedOut) { 'timeout' } else { "exit $($probe.ExitCode)" }) }
            [void]$actions.Add("Uninstalled npm package $package")
        }
        catch { [void]$errors.Add("Failed to uninstall npm package ${package}: $($_.Exception.Message)") }
    }
    foreach ($package in @($Delta.NewWingetPackages | Where-Object { $_ -and $_ -notmatch '^__' })) {
        try {
            $wingetCommand = Get-Command winget.exe -ErrorAction Stop | Select-Object -First 1
            $probe = Invoke-AcceptanceCapturedCommand -FilePath ([string]$wingetCommand.Source) -ArgumentList @(
                'uninstall', '--id', $package, '--exact', '--silent', '--disable-interactivity', '--accept-source-agreements'
            ) -TimeoutSec 300
            if ($probe.TimedOut -or $probe.ExitCode -ne 0) { throw $(if ($probe.TimedOut) { 'timeout' } else { "exit $($probe.ExitCode)" }) }
            [void]$actions.Add("Uninstalled winget package $package")
        }
        catch { [void]$errors.Add("Failed to uninstall winget package ${package}: $($_.Exception.Message)") }
    }
    foreach ($service in @($Delta.NewServices)) {
        try { & sc.exe stop $service.Name 2>&1 | Out-Null; & sc.exe delete $service.Name 2>&1 | Out-Null; [void]$actions.Add("Removed service $($service.Name)") }
        catch { [void]$errors.Add("Failed to remove service $($service.Name): $($_.Exception.Message)") }
    }
    foreach ($task in @($Delta.NewScheduledTasks | Where-Object { $_.TaskName -notmatch '^CCDI-Acceptance-Resume' })) {
        try { Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop; [void]$actions.Add("Removed task $($task.TaskPath)$($task.TaskName)") }
        catch { [void]$errors.Add("Failed to remove task $($task.TaskPath)$($task.TaskName): $($_.Exception.Message)") }
    }

    try { [Environment]::SetEnvironmentVariable("Path", [string]$Baseline.UserPath, "User"); [void]$actions.Add("Restored user PATH") }
    catch { [void]$errors.Add("Failed to restore user PATH: $($_.Exception.Message)") }
    try { [Environment]::SetEnvironmentVariable("Path", [string]$Baseline.MachinePath, "Machine"); [void]$actions.Add("Restored machine PATH") }
    catch { [void]$errors.Add("Failed to restore machine PATH: $($_.Exception.Message)") }
    try { Restore-AcceptanceRegistry -BaselineRegistry $Baseline.Registry; [void]$actions.Add("Restored tracked registry values") }
    catch { [void]$errors.Add("Failed to restore registry: $($_.Exception.Message)") }
    try { Restore-AcceptanceSettings -Baseline $Baseline -SettingsBytes $SettingsBytes; [void]$actions.Add("Restored settings.json") }
    catch { [void]$errors.Add("Failed to restore settings.json: $($_.Exception.Message)") }

    $allowed = @($AllowedCleanupRoots | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') })
    foreach ($path in @($Delta.CreatedPaths | Sort-Object Length -Descending)) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        if (Test-AcceptanceProtectedPath -Path $path -ProjectRoot $ProjectRoot -ControlRoot $ControlRoot -ResultRoot $ResultRoot) { continue }
        $full = [IO.Path]::GetFullPath($path)
        $withinAllowed = $false
        foreach ($root in $allowed) { if ($full -eq $root -or $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { $withinAllowed = $true; break } }
        if (-not $withinAllowed) { [void]$errors.Add("Refused unowned path deletion: $full"); continue }
        $removed = $false
        $lastRemoveError = $null
        for ($attempt = 1; $attempt -le 3 -and -not $removed; $attempt++) {
            try { Remove-Item -LiteralPath $full -Force -Recurse -ErrorAction Stop; $removed = $true; [void]$actions.Add("Removed created path $full") }
            catch { $lastRemoveError = $_.Exception.Message; Start-Sleep -Milliseconds 500 }
        }
        if (-not $removed) { [void]$errors.Add("LOCKED_PATH: Failed to remove $full after 3 attempts: $lastRemoveError") }
    }

    foreach ($name in @("CCDI_TEST_MODE", "CCDI_TEST_USERPROFILE", "CCDI_TEST_DESKTOP", "CCDI_TEST_ARTIFACT_ROOT", "CCDI_TEST_API_STATUS", "CCDI_ACCEPTANCE_VM")) {
        [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }

    [ordered]@{ Success = ($errors.Count -eq 0); Actions = @($actions); Errors = @($errors) }
}

function Test-AcceptanceBaselineEquivalent {
    param($Baseline, $Candidate)
    $differences = New-Object System.Collections.ArrayList
    if ($Baseline.UserPath -ne $Candidate.UserPath) { [void]$differences.Add("User PATH differs") }
    if ($Baseline.MachinePath -ne $Candidate.MachinePath) { [void]$differences.Add("Machine PATH differs") }
    if (($Baseline.Settings | ConvertTo-Json -Compress) -ne ($Candidate.Settings | ConvertTo-Json -Compress)) { [void]$differences.Add("settings.json differs") }
    foreach ($name in @("claude", "node", "npm")) {
        $before = $Baseline.Commands | Where-Object Name -eq $name | Select-Object -First 1
        $after = $Candidate.Commands | Where-Object Name -eq $name | Select-Object -First 1
        if (($before | ConvertTo-Json -Compress) -ne ($after | ConvertTo-Json -Compress)) { [void]$differences.Add("command $name differs") }
    }
    if (($Baseline.NpmGlobal | ConvertTo-Json -Depth 8 -Compress) -ne ($Candidate.NpmGlobal | ConvertTo-Json -Depth 8 -Compress)) { [void]$differences.Add("npm global package list differs") }
    if (($Baseline.Winget | ConvertTo-Json -Depth 8 -Compress) -ne ($Candidate.Winget | ConvertTo-Json -Depth 8 -Compress)) { [void]$differences.Add("winget package list differs") }
    if (($Baseline.Registry | ConvertTo-Json -Depth 8 -Compress) -ne ($Candidate.Registry | ConvertTo-Json -Depth 8 -Compress)) { [void]$differences.Add("tracked registry differs") }
    if (($Baseline.Files | ConvertTo-Json -Depth 8 -Compress) -ne ($Candidate.Files | ConvertTo-Json -Depth 8 -Compress)) { [void]$differences.Add("tracked files differ") }
    if (($Baseline.Services | ConvertTo-Json -Depth 8 -Compress) -ne ($Candidate.Services | ConvertTo-Json -Depth 8 -Compress)) { [void]$differences.Add("related services differ") }
    if (($Baseline.ScheduledTasks | ConvertTo-Json -Depth 8 -Compress) -ne ($Candidate.ScheduledTasks | ConvertTo-Json -Depth 8 -Compress)) { [void]$differences.Add("related scheduled tasks differ") }
    [PSCustomObject]@{ Equivalent = ($differences.Count -eq 0); Differences = @($differences) }
}

function Register-AcceptanceResume {
    param($Paths, [string]$EntryScript, [hashtable]$State)
    $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Paths.ResumeState -Encoding UTF8
    $resumeArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$EntryScript`" -Resume -Mode $($State.Mode) -Version $($State.Version) -ControlRoot `"$($Paths.Root)`""
    if ($State.Mode -eq "Live") { $resumeArguments += " -AcknowledgeRealInstall" }
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $resumeArguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $Paths.ResumeUserTask -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

    $bootstrap = Join-Path $Paths.Root "resume-bootstrap.ps1"
    @"
`$ErrorActionPreference = 'SilentlyContinue'
for (`$i = 0; `$i -lt 120; `$i++) {
    schtasks.exe /Run /TN '$($Paths.ResumeUserTask)' | Out-Null
    if (`$LASTEXITCODE -eq 0) { exit 0 }
    Start-Sleep -Seconds 5
}
exit 1
"@ | Set-Content -LiteralPath $bootstrap -Encoding UTF8
    $taskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$bootstrap`""
    & schtasks.exe /Create /TN $Paths.ResumeTask /SC ONSTART /RU SYSTEM /RL HIGHEST /TR $taskCommand /F | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to create SYSTEM resume bootstrap task" }
}

function Remove-AcceptanceResume {
    param($Paths)
    & schtasks.exe /Delete /TN $Paths.ResumeTask /F 2>$null | Out-Null
    & schtasks.exe /Delete /TN $Paths.ResumeUserTask /F 2>$null | Out-Null
    Remove-Item -LiteralPath $Paths.ResumeState -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Paths.Root "resume-bootstrap.ps1") -Force -ErrorAction SilentlyContinue
}
