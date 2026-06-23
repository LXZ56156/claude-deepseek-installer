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
            $timeoutStdout = ''
            $timeoutStderr = ''
            try { if ($stdoutTask.Wait(2000)) { $timeoutStdout = [string]$stdoutTask.Result } } catch { }
            try { if ($stderrTask.Wait(2000)) { $timeoutStderr = [string]$stderrTask.Result } } catch { }
            return [ordered]@{ ExitCode = $null; TimedOut = $true; StdOut = $timeoutStdout; StdErr = $timeoutStderr }
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
        Baseline = [IO.Path]::GetFullPath((Join-Path $ControlRoot "runs\$RunId\baseline"))
        Runs = [IO.Path]::GetFullPath((Join-Path $ControlRoot "runs"))
        Run = [IO.Path]::GetFullPath((Join-Path $ControlRoot "runs\$RunId"))
        ResumeState = [IO.Path]::GetFullPath((Join-Path $ControlRoot "resume-state.json"))
        ResumeCleanupReport = [IO.Path]::GetFullPath((Join-Path $ControlRoot "resume-task-cleanup.json"))
        ResumeRegistrationReport = [IO.Path]::GetFullPath((Join-Path $ControlRoot "resume-registration.json"))
        ResumeBootstrap = [IO.Path]::GetFullPath((Join-Path $ControlRoot "resume-bootstrap.ps1"))
        LockFile = [IO.Path]::GetFullPath((Join-Path $ControlRoot ".acceptance.lock"))
        ResumeTask = "CCDI-Acceptance-Resume"
        ResumeUserTask = "CCDI-Acceptance-Resume-User"
    }
}

function Enter-AcceptanceInstanceLock {
    param([string]$ControlRoot = "C:\CCDI-Acceptance-Control")
    $root = [IO.Path]::GetFullPath($ControlRoot)
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $lockPath = Join-Path $root ".acceptance.lock"
    try {
        $stream = New-Object IO.FileStream($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $payload = [Text.Encoding]::UTF8.GetBytes("PID=$PID`r`nUSER=$([Security.Principal.WindowsIdentity]::GetCurrent().Name)`r`nSTARTED=$((Get-Date).ToString('o'))`r`n")
        $stream.SetLength(0); $stream.Write($payload, 0, $payload.Length); $stream.Flush($true)
        return [PSCustomObject]@{ Path = $lockPath; Stream = $stream }
    }
    catch {
        throw "Another acceptance instance already owns ControlRoot $root"
    }
}

function Exit-AcceptanceInstanceLock {
    param($Lock)
    if (-not $Lock) { return }
    try { if ($Lock.Stream) { $Lock.Stream.Dispose() } } catch { }
    try { Remove-Item -LiteralPath $Lock.Path -Force -ErrorAction SilentlyContinue } catch { }
}

function Get-AcceptancePathKey {
    param([string]$Path)
    $bytes = [Text.Encoding]::UTF8.GetBytes(([IO.Path]::GetFullPath($Path)).ToUpperInvariant())
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function ConvertTo-AcceptanceFileComparable {
    param($Item)
    [ordered]@{ Path = [string]$Item.Path; Type = [string]$Item.Type; Exists = [bool]$Item.Exists; Length = [long]$Item.Length; SHA256 = [string]$Item.SHA256 }
}

function Get-AcceptanceFileState {
    param([string[]]$Roots, [switch]$CaptureBytes, [string]$BackupRoot)
    $result = New-Object System.Collections.ArrayList
    if ($CaptureBytes -and -not $BackupRoot) { throw "BackupRoot is required when CaptureBytes is enabled" }
    if ($CaptureBytes -and -not (Test-Path -LiteralPath $BackupRoot)) { New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null }
    $addFile = {
        param($Item, [string]$Type)
        $backupPath = $null
        if ($CaptureBytes -and $Type -eq 'File') {
            $backupPath = Join-Path $BackupRoot ((Get-AcceptancePathKey -Path $Item.FullName) + '.bin')
            [IO.File]::Copy($Item.FullName, $backupPath, $true)
        }
        $hash = if ($Type -eq 'File') { try { (Get-FileHash -LiteralPath $Item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $null } } else { $null }
        [void]$result.Add([ordered]@{ Path = $Item.FullName; Type = $Type; Exists = $true; Length = if ($Type -eq 'File') { $Item.Length } else { 0 }; SHA256 = $hash; BackupPath = $backupPath })
    }
    foreach ($root in @($Roots | Where-Object { $_ } | Select-Object -Unique)) {
        $fullRoot = [IO.Path]::GetFullPath($root)
        $exists = Test-Path -LiteralPath $fullRoot
        if ($exists -and (Test-Path -LiteralPath $fullRoot -PathType Leaf)) {
            & $addFile (Get-Item -LiteralPath $fullRoot -Force) 'File'
            continue
        }
        [void]$result.Add([ordered]@{ Path = $fullRoot; Type = "Directory"; Exists = $exists; Length = 0; SHA256 = $null; BackupPath = $null })
        if (-not $exists) { continue }
        foreach ($item in Get-ChildItem -LiteralPath $fullRoot -Force -Recurse -ErrorAction SilentlyContinue) {
            if ($item.FullName -match '\\.codex(?:\\|$)') { continue }
            if ($item.FullName -match '\\.claude\\_git_cache\.json$') { continue }
            & $addFile $item $(if ($item.PSIsContainer) { 'Directory' } else { 'File' })
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
    $lastFailure = 'unknown'
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $export = Join-Path $TempRoot ("winget-" + [guid]::NewGuid().ToString("N") + ".json")
        try {
            $probe = Invoke-AcceptanceCapturedCommand -FilePath ([string]$winget.Source) -ArgumentList @(
                'export', '--output', $export, '--include-versions', '--accept-source-agreements', '--disable-interactivity'
            ) -TimeoutSec 180
            if ($probe.TimedOut) { $lastFailure = 'timeout'; continue }
            if ($null -eq $probe.ExitCode) { $lastFailure = 'start-error'; continue }
            if (-not (Test-Path -LiteralPath $export)) { $lastFailure = 'no-export'; continue }
            $data = Get-Content -LiteralPath $export -Raw -Encoding UTF8 | ConvertFrom-Json
            return @($data.Sources.Packages | ForEach-Object {
                [ordered]@{ Id = [string]$_.PackageIdentifier; Version = [string]$_.Version }
            } | Sort-Object Id)
        }
        catch { $lastFailure = 'invalid-output' }
        finally { Remove-Item -LiteralPath $export -Force -ErrorAction SilentlyContinue }
    }
    return @([ordered]@{ Id = '__UNAVAILABLE__'; Version = $lastFailure })
}

function Assert-AcceptanceSnapshotUsable {
    param($Snapshot, [string]$Label)
    $unavailable = @($Snapshot.Winget | Where-Object { $_.Id -eq '__UNAVAILABLE__' })
    if ($unavailable.Count -gt 0) { throw "$Label winget inventory unavailable after retries: $($unavailable[0].Version)" }
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
        [ordered]@{ ProcessId = $_.ProcessId; ParentProcessId = $_.ParentProcessId; Name = $_.Name; ExecutablePath = $_.ExecutablePath; CommandLine = $_.CommandLine; CreationDate = [string]$_.CreationDate }
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
    $desktop = if ($env:CCDI_TEST_DESKTOP) { $env:CCDI_TEST_DESKTOP } else { [Environment]::GetFolderPath("Desktop") }
    $desktopProjects = @()
    if ($desktop -and (Test-Path -LiteralPath $desktop -PathType Container)) {
        $desktopProjects = @(Get-ChildItem -LiteralPath $desktop -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'ClaudeCode-Test' -or $_.Name -match '^ClaudeCode-Test-\d{8}-\d{6}(?:-\d+)?$' } | Select-Object -ExpandProperty FullName)
    }
    $roots = @(
        (Join-Path $env:USERPROFILE ".claude"),
        (Join-Path $env:USERPROFILE ".claude-deepseek-installer"),
        (Join-Path $env:USERPROFILE ".claude.json"),
        (Join-Path $env:USERPROFILE ".local\bin"),
        (Join-Path $env:USERPROFILE ".local\share\claude"),
        (Join-Path $env:APPDATA "npm"),
        (Join-Path $env:LOCALAPPDATA "Programs\claude"),
        (Join-Path $env:LOCALAPPDATA "AnthropicClaude"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\claude.exe"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\claude.cmd"),
        (Join-Path $env:ProgramFiles "nodejs"),
        $(if ($desktop) { Join-Path $desktop "ClaudeCode-Test" })
    ) + @($desktopProjects) + @($AdditionalRoots)
    @($roots | Where-Object { $_ -and ([IO.Path]::GetFullPath($_) -notmatch '\\.codex(?:\\|$)') } | Select-Object -Unique)
}

function Get-AcceptanceEnvironmentSnapshot {
    param(
        [string]$ProjectRoot,
        [string]$TempRoot,
        [string[]]$AdditionalRoots = @(),
        [string[]]$KnownRootsOverride,
        [switch]$CaptureFileBytes,
        [string]$FileBackupRoot
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
        ProcessPath = $env:Path
        Commands = @("claude", "node", "npm", "winget") | ForEach-Object { Get-AcceptanceCommandState $_ }
        NpmGlobal = @(Get-AcceptanceNpmPackages)
        Winget = @(Get-AcceptanceWingetPackages -TempRoot $TempRoot)
        Registry = @(Get-AcceptanceRegistryState)
        Files = @(Get-AcceptanceFileState -Roots $(if ($KnownRootsOverride) { $KnownRootsOverride } else { Get-AcceptanceKnownRoots -AdditionalRoots $AdditionalRoots }) -CaptureBytes:$CaptureFileBytes -BackupRoot $FileBackupRoot)
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
        (((ConvertTo-AcceptanceFileComparable $beforeFiles[$_]) | ConvertTo-Json -Compress) -ne ((ConvertTo-AcceptanceFileComparable $afterFiles[$_]) | ConvertTo-Json -Compress))
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
        ProcessPathChanged = $Before.ProcessPath -ne $After.ProcessPath
        RegistryChanged = (($Before.Registry | ConvertTo-Json -Depth 8 -Compress) -ne ($After.Registry | ConvertTo-Json -Depth 8 -Compress))
        SettingsChanged = (($Before.Settings | ConvertTo-Json -Compress) -ne ($After.Settings | ConvertTo-Json -Compress))
        NewProcesses = @($After.Processes | Where-Object {
            $afterProcessId = [int]$_.ProcessId
            $afterProcessId -notin @($Before.Processes | ForEach-Object { [int]$_.ProcessId })
        })
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

function New-AcceptanceOwnership {
    param(
        [string[]]$PathRoots = @(), [string[]]$PathPatterns = @(),
        [string[]]$NpmPackages = @(), [string[]]$WingetPackages = @(),
        [string[]]$Services = @(), [string[]]$ScheduledTasks = @(), [int[]]$ProcessIds = @()
    )
    [PSCustomObject]@{
        PathRoots = @($PathRoots | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') } | Select-Object -Unique)
        PathPatterns = @($PathPatterns | Where-Object { $_ } | Select-Object -Unique)
        NpmPackages = @($NpmPackages | Where-Object { $_ } | Select-Object -Unique)
        WingetPackages = @($WingetPackages | Where-Object { $_ } | Select-Object -Unique)
        Services = @($Services | Where-Object { $_ } | Select-Object -Unique)
        ScheduledTasks = @($ScheduledTasks | Where-Object { $_ } | Select-Object -Unique)
        ProcessIds = @($ProcessIds | Where-Object { $_ } | Select-Object -Unique)
    }
}

function Test-AcceptanceOwnedPath {
    param([string]$Path, $Ownership)
    if (-not $Ownership) { return $false }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($root in @($Ownership.PathRoots)) {
        if ($full -eq $root -or $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    foreach ($pattern in @($Ownership.PathPatterns)) { if ($full -match [string]$pattern) { return $true } }
    return $false
}

function Test-AcceptanceAllowedPath {
    param([string]$Path, [string[]]$AllowedRoots)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($rootValue in @($AllowedRoots)) {
        $root = [IO.Path]::GetFullPath($rootValue).TrimEnd('\')
        if ($full -eq $root -or $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Restore-AcceptanceTrackedPath {
    param($BaselineItem, $Ownership, [string[]]$AllowedRoots, [string]$ProjectRoot, [string]$ControlRoot, [string]$ResultRoot)
    $path = [string]$BaselineItem.Path
    if (-not (Test-AcceptanceOwnedPath -Path $path -Ownership $Ownership)) { throw "UNOWNED_PATH: $path" }
    if (-not (Test-AcceptanceAllowedPath -Path $path -AllowedRoots $AllowedRoots)) { throw "OUTSIDE_CONTROLLED_ROOT: $path" }
    if (Test-AcceptanceProtectedPath -Path $path -ProjectRoot $ProjectRoot -ControlRoot $ControlRoot -ResultRoot $ResultRoot) { throw "PROTECTED_PATH: $path" }
    if ([string]$BaselineItem.Type -eq 'Directory') {
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        return
    }
    if (-not $BaselineItem.BackupPath -or -not (Test-Path -LiteralPath $BaselineItem.BackupPath -PathType Leaf)) {
        throw "MISSING_BASELINE_BYTES: $path"
    }
    if (Test-Path -LiteralPath $path -PathType Container) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop }
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::Copy([string]$BaselineItem.BackupPath, $path, $true)
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($hash -ne [string]$BaselineItem.SHA256) { throw "RESTORE_HASH_MISMATCH: $path" }
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
        [int[]]$ProtectedProcessIds,
        $Ownership = (New-AcceptanceOwnership)
    )
    $actions = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $reports = New-Object System.Collections.ArrayList

    foreach ($process in @($Delta.NewProcesses)) {
        if ($process.ProcessId -in $ProtectedProcessIds) { continue }
        if ($process.ProcessId -notin @($Ownership.ProcessIds)) { [void]$errors.Add("UNOWNED_PROCESS: $($process.ProcessId) $($process.Name)"); continue }
        try {
            $currentProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$process.ProcessId)" -ErrorAction Stop
            if (-not $currentProcess) { [void]$actions.Add("Process $($process.ProcessId) already exited"); continue }
            foreach ($identityField in @('Name', 'ExecutablePath', 'CommandLine', 'CreationDate')) {
                if ([string]$process.$identityField -cne [string]$currentProcess.$identityField) { throw "PID_REUSED: $($process.ProcessId) identity field $identityField changed" }
            }
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            [void]$actions.Add("Stopped process $($process.ProcessId) $($process.Name)")
        }
        catch { [void]$errors.Add("Failed to stop process $($process.ProcessId): $($_.Exception.Message)") }
    }

    foreach ($package in @($Delta.NewNpmPackages | Where-Object { $_ -and $_ -notmatch '^__' })) {
        if ($package -notin @($Ownership.NpmPackages)) { [void]$reports.Add("UNOWNED_NPM_PACKAGE: $package"); continue }
        try {
            $npmCommand = Get-Command npm.cmd -ErrorAction Stop | Select-Object -First 1
            $probe = Invoke-AcceptanceCapturedCommand -FilePath ([string]$npmCommand.Source) -ArgumentList @('uninstall', '-g', $package) -TimeoutSec 180
            if ($probe.TimedOut -or $probe.ExitCode -ne 0) { throw $(if ($probe.TimedOut) { 'timeout' } else { "exit $($probe.ExitCode)" }) }
            [void]$actions.Add("Uninstalled npm package $package")
        }
        catch { [void]$errors.Add("Failed to uninstall npm package ${package}: $($_.Exception.Message)") }
    }
    foreach ($package in @($Delta.NewWingetPackages | Where-Object { $_ -and $_ -notmatch '^__' })) {
        if ($package -notin @($Ownership.WingetPackages)) { [void]$reports.Add("UNOWNED_WINGET_PACKAGE: $package"); continue }
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
        if ($service.Name -notin @($Ownership.Services)) { [void]$reports.Add("UNOWNED_SERVICE: $($service.Name)"); continue }
        try { & sc.exe stop $service.Name 2>&1 | Out-Null; & sc.exe delete $service.Name 2>&1 | Out-Null; [void]$actions.Add("Removed service $($service.Name)") }
        catch { [void]$errors.Add("Failed to remove service $($service.Name): $($_.Exception.Message)") }
    }
    foreach ($task in @($Delta.NewScheduledTasks | Where-Object { $_.TaskName -notmatch '^CCDI-Acceptance-Resume' })) {
        $taskKey = "$($task.TaskPath)$($task.TaskName)"
        if ($taskKey -notin @($Ownership.ScheduledTasks)) { [void]$reports.Add("UNOWNED_TASK: $taskKey"); continue }
        try { Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop; [void]$actions.Add("Removed task $($task.TaskPath)$($task.TaskName)") }
        catch { [void]$errors.Add("Failed to remove task $($task.TaskPath)$($task.TaskName): $($_.Exception.Message)") }
    }

    if ($Delta.UserPathChanged) { try { [Environment]::SetEnvironmentVariable("Path", [string]$Baseline.UserPath, "User"); [void]$actions.Add("Restored user PATH") } catch { [void]$errors.Add("Failed to restore user PATH: $($_.Exception.Message)") } }
    if ($Delta.MachinePathChanged) { try { [Environment]::SetEnvironmentVariable("Path", [string]$Baseline.MachinePath, "Machine"); [void]$actions.Add("Restored machine PATH") } catch { [void]$errors.Add("Failed to restore machine PATH: $($_.Exception.Message)") } }
    if ($Delta.ProcessPathChanged) { try { $env:Path = [string]$Baseline.ProcessPath; [void]$actions.Add("Restored process PATH") } catch { [void]$errors.Add("Failed to restore process PATH: $($_.Exception.Message)") } }
    if ($Delta.RegistryChanged) { try { Restore-AcceptanceRegistry -BaselineRegistry $Baseline.Registry; [void]$actions.Add("Restored tracked registry values") } catch { [void]$errors.Add("Failed to restore registry: $($_.Exception.Message)") } }
    if ($Delta.SettingsChanged) { try { Restore-AcceptanceSettings -Baseline $Baseline -SettingsBytes $SettingsBytes; [void]$actions.Add("Restored settings.json") } catch { [void]$errors.Add("Failed to restore settings.json: $($_.Exception.Message)") } }

    $allowed = @($AllowedCleanupRoots | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') })
    $baselineFiles = @{}; foreach ($item in @($Baseline.Files)) { $baselineFiles[[string]$item.Path] = $item }
    $restorePaths = @(@($Delta.RemovedPaths) + @($Delta.ModifiedPaths) | Select-Object -Unique | Sort-Object { $_.Length })
    foreach ($path in $restorePaths) {
        if (-not $baselineFiles.ContainsKey([string]$path)) { [void]$errors.Add("NO_BASELINE_ENTRY: $path"); continue }
        try { Restore-AcceptanceTrackedPath -BaselineItem $baselineFiles[[string]$path] -Ownership $Ownership -AllowedRoots $allowed -ProjectRoot $ProjectRoot -ControlRoot $ControlRoot -ResultRoot $ResultRoot; [void]$actions.Add("Restored tracked path $path") }
        catch { [void]$errors.Add($_.Exception.Message) }
    }
    foreach ($path in @($Delta.CreatedPaths | Sort-Object Length -Descending)) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        if (Test-AcceptanceProtectedPath -Path $path -ProjectRoot $ProjectRoot -ControlRoot $ControlRoot -ResultRoot $ResultRoot) { continue }
        $full = [IO.Path]::GetFullPath($path)
        if (-not (Test-AcceptanceAllowedPath -Path $full -AllowedRoots $allowed)) { [void]$errors.Add("OUTSIDE_CONTROLLED_ROOT: $full"); continue }
        if (-not (Test-AcceptanceOwnedPath -Path $full -Ownership $Ownership)) { [void]$reports.Add("UNOWNED_PATH: $full"); continue }
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

    [ordered]@{ Success = ($errors.Count -eq 0); Actions = @($actions); Errors = @($errors); Reports = @($reports); Ownership = $Ownership }
}

function Test-AcceptanceBaselineEquivalent {
    param($Baseline, $Candidate, [int[]]$IgnoredProcessIds = @())
    $differences = New-Object System.Collections.ArrayList
    if ($Baseline.UserPath -ne $Candidate.UserPath) { [void]$differences.Add("User PATH differs") }
    if ($Baseline.MachinePath -ne $Candidate.MachinePath) { [void]$differences.Add("Machine PATH differs") }
    if ($Baseline.ProcessPath -ne $Candidate.ProcessPath) { [void]$differences.Add("Process PATH differs") }
    if (($Baseline.Settings | ConvertTo-Json -Compress) -ne ($Candidate.Settings | ConvertTo-Json -Compress)) { [void]$differences.Add("settings.json differs") }
    foreach ($name in @("claude", "node", "npm")) {
        $before = $Baseline.Commands | Where-Object Name -eq $name | Select-Object -First 1
        $after = $Candidate.Commands | Where-Object Name -eq $name | Select-Object -First 1
        if (($before | ConvertTo-Json -Compress) -ne ($after | ConvertTo-Json -Compress)) { [void]$differences.Add("command $name differs") }
    }
    if (($Baseline.NpmGlobal | ConvertTo-Json -Depth 8 -Compress) -ne ($Candidate.NpmGlobal | ConvertTo-Json -Depth 8 -Compress)) { [void]$differences.Add("npm global package list differs") }
    if (($Baseline.Winget | ConvertTo-Json -Depth 8 -Compress) -ne ($Candidate.Winget | ConvertTo-Json -Depth 8 -Compress)) { [void]$differences.Add("winget package list differs") }
    if (($Baseline.Registry | ConvertTo-Json -Depth 8 -Compress) -ne ($Candidate.Registry | ConvertTo-Json -Depth 8 -Compress)) { [void]$differences.Add("tracked registry differs") }
    $baselineComparableFiles = @($Baseline.Files | ForEach-Object { ConvertTo-AcceptanceFileComparable $_ })
    $candidateComparableFiles = @($Candidate.Files | ForEach-Object { ConvertTo-AcceptanceFileComparable $_ })
    if (($baselineComparableFiles | ConvertTo-Json -Depth 8 -Compress) -ne ($candidateComparableFiles | ConvertTo-Json -Depth 8 -Compress)) { [void]$differences.Add("tracked files differ") }
    if (($Baseline.Services | ConvertTo-Json -Depth 8 -Compress) -ne ($Candidate.Services | ConvertTo-Json -Depth 8 -Compress)) { [void]$differences.Add("related services differ") }
    if (($Baseline.ScheduledTasks | ConvertTo-Json -Depth 8 -Compress) -ne ($Candidate.ScheduledTasks | ConvertTo-Json -Depth 8 -Compress)) { [void]$differences.Add("related scheduled tasks differ") }
    $baselineProcesses = @($Baseline.Processes | Where-Object { [int]$_.ProcessId -notin $IgnoredProcessIds })
    $candidateProcesses = @($Candidate.Processes | Where-Object { [int]$_.ProcessId -notin $IgnoredProcessIds })
    if (($baselineProcesses | ConvertTo-Json -Depth 8 -Compress) -ne ($candidateProcesses | ConvertTo-Json -Depth 8 -Compress)) { [void]$differences.Add("related processes differ") }
    [PSCustomObject]@{ Equivalent = ($differences.Count -eq 0); Differences = @($differences) }
}

function Write-AcceptanceJsonFileAtomic {
    param([string]$Path, $Value)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    $temporary = "$Path.tmp.$([guid]::NewGuid().ToString('N'))"
    try {
        $json = $Value | ConvertTo-Json -Depth 30
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Atomic JSON write did not publish '$Path'" }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Write-AcceptanceResumeState {
    param($Paths, $State, [scriptblock]$StateWriter)
    if ($StateWriter) { & $StateWriter $Paths.ResumeState $State; return }
    Write-AcceptanceJsonFileAtomic -Path $Paths.ResumeState -Value $State
}

function Test-AcceptanceObjectProperty {
    param($Value, [string]$Name)
    if ($null -eq $Value) { return $false }
    if ($Value -is [Collections.IDictionary]) { return $Value.Contains($Name) }
    return $Value.PSObject.Properties.Name -contains $Name
}

function Get-AcceptanceObjectProperty {
    param($Value, [string]$Name)
    if (-not (Test-AcceptanceObjectProperty -Value $Value -Name $Name)) { return $null }
    if ($Value -is [Collections.IDictionary]) { $result = $Value[$Name] }
    else { $result = $Value.$Name }
    if ($result -is [Array]) { return ,$result }
    return $result
}

function Assert-AcceptanceResumeState {
    param($State, [string]$StatePath, [Nullable[int]]$ScenarioCount, $Paths)

    function Throw-InvalidResumeField {
        param([string]$Field, [string]$Reason)
        throw "Invalid resume state '$StatePath': field '$Field' $Reason"
    }
    function Require-ResumeField {
        param([string]$Name)
        if (-not (Test-AcceptanceObjectProperty -Value $State -Name $Name)) { Throw-InvalidResumeField $Name 'is missing' }
        $result = Get-AcceptanceObjectProperty -Value $State -Name $Name
        if ($result -is [Array]) { return ,$result }
        return $result
    }
    function Require-ResumeString {
        param([string]$Name, [switch]$AllowEmpty)
        $value = Require-ResumeField $Name
        if ($value -isnot [string] -or (-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($value))) { Throw-InvalidResumeField $Name 'must be a non-empty string' }
        return [string]$value
    }
    function Require-ResumeBoolean {
        param([string]$Name)
        $value = Require-ResumeField $Name
        if ($value -isnot [bool]) { Throw-InvalidResumeField $Name 'must be a boolean' }
        return [bool]$value
    }
    function Require-ResumeArray {
        param([string]$Name)
        $value = Require-ResumeField $Name
        if ($value -is [string] -or $value -isnot [Array]) { Throw-InvalidResumeField $Name 'must be an array' }
        return ,@($value)
    }
    function Test-ResumeInteger {
        param($Value)
        if ($null -eq $Value) { return $false }
        return [Type]::GetTypeCode($Value.GetType()) -in @(
            [TypeCode]::SByte, [TypeCode]::Byte, [TypeCode]::Int16, [TypeCode]::UInt16,
            [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64
        )
    }
    function Test-ResumeNumber {
        param($Value)
        if ($null -eq $Value) { return $false }
        return [Type]::GetTypeCode($Value.GetType()) -in @(
            [TypeCode]::SByte, [TypeCode]::Byte, [TypeCode]::Int16, [TypeCode]::UInt16,
            [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64,
            [TypeCode]::Single, [TypeCode]::Double, [TypeCode]::Decimal
        )
    }
    function Assert-ResumeOwnership {
        param($Ownership, [string]$Prefix)
        if ($null -eq $Ownership -or $Ownership -is [string] -or $Ownership -is [Array]) { Throw-InvalidResumeField $Prefix 'must be an object' }
        foreach ($name in @('PathRoots', 'PathPatterns', 'NpmPackages', 'WingetPackages', 'Services', 'ScheduledTasks', 'ProcessIds')) {
            if (-not (Test-AcceptanceObjectProperty $Ownership $name)) { Throw-InvalidResumeField "$Prefix.$name" 'is missing' }
            $values = Get-AcceptanceObjectProperty $Ownership $name
            if ($values -is [string] -or $values -isnot [Array]) { Throw-InvalidResumeField "$Prefix.$name" 'must be an array' }
            foreach ($value in @($values)) {
                if ($name -eq 'ProcessIds') {
                    if (-not (Test-ResumeInteger $value) -or [int64]$value -lt 0 -or [int64]$value -gt [int]::MaxValue) { Throw-InvalidResumeField "$Prefix.$name" 'must contain only non-negative integers' }
                }
                elseif ($value -isnot [string]) { Throw-InvalidResumeField "$Prefix.$name" 'must contain only strings' }
            }
        }
    }
    function Assert-ResumeStageResult {
        param($Item, [string]$Prefix)
        if ($null -eq $Item -or $Item -is [string] -or $Item -is [Array]) { Throw-InvalidResumeField $Prefix 'must be an object' }
        foreach ($name in @('Name', 'Stdout', 'Stderr', 'Result')) {
            if ((Get-AcceptanceObjectProperty $Item $name) -isnot [string] -or [string]::IsNullOrWhiteSpace([string](Get-AcceptanceObjectProperty $Item $name))) { Throw-InvalidResumeField "$Prefix.$name" 'must be a non-empty string' }
        }
        $timedOut = Get-AcceptanceObjectProperty $Item 'TimedOut'
        if ($timedOut -isnot [bool]) { Throw-InvalidResumeField "$Prefix.TimedOut" 'must be a boolean' }
        if (-not (Test-AcceptanceObjectProperty $Item 'ExitCode')) { Throw-InvalidResumeField "$Prefix.ExitCode" 'is missing' }
        $exitCode = Get-AcceptanceObjectProperty $Item 'ExitCode'
        if ($null -ne $exitCode -and (-not (Test-ResumeInteger $exitCode) -or [int64]$exitCode -lt [int]::MinValue -or [int64]$exitCode -gt [int]::MaxValue)) { Throw-InvalidResumeField "$Prefix.ExitCode" 'must be null or an integer' }
        $duration = Get-AcceptanceObjectProperty $Item 'DurationSec'
        if (-not (Test-ResumeNumber $duration) -or [double]$duration -lt 0 -or [double]::IsNaN([double]$duration) -or [double]::IsInfinity([double]$duration)) { Throw-InvalidResumeField "$Prefix.DurationSec" 'must be a finite non-negative number' }
    }

    if ($null -eq $State -or $State -is [string] -or $State -is [Array]) { Throw-InvalidResumeField '<root>' 'must be an object' }
    $schemaVersion = Require-ResumeField 'SchemaVersion'
    if (-not (Test-ResumeInteger $schemaVersion) -or [int64]$schemaVersion -ne 3) { Throw-InvalidResumeField 'SchemaVersion' 'must be the integer 3' }
    $runId = Require-ResumeString 'RunId'
    if ($runId -notmatch '^\d{8}-\d{6}-\d{3}$') { Throw-InvalidResumeField 'RunId' 'must match yyyyMMdd-HHmmss-fff' }
    $mode = Require-ResumeString 'Mode'
    if ($mode -notin @('TestSafe', 'Live')) { Throw-InvalidResumeField 'Mode' 'must be TestSafe or Live' }
    $version = Require-ResumeString 'Version'
    if ($version -notmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') { Throw-InvalidResumeField 'Version' 'must be a semantic version' }
    $credentialTarget = Require-ResumeString 'CredentialTarget'
    if ($credentialTarget.Length -gt 128 -or $credentialTarget -notmatch '^[0-9A-Za-z_.:-]+$') { Throw-InvalidResumeField 'CredentialTarget' 'contains unsupported characters' }
    $realInstallAcknowledged = Require-ResumeBoolean 'AcknowledgeRealInstall'
    $restartAcknowledged = Require-ResumeBoolean 'AcknowledgeRestart'
    if ($mode -eq 'Live' -and (-not $realInstallAcknowledged -or -not $restartAcknowledged)) {
        Throw-InvalidResumeField 'AcknowledgeRealInstall/AcknowledgeRestart' 'must both be true for Live resume'
    }
    $phase = Require-ResumeString 'Phase'
    if ($phase -ne 'resume-cleanup-pending') { Throw-InvalidResumeField 'Phase' 'must be resume-cleanup-pending' }
    $nextIndex = Require-ResumeField 'NextScenarioIndex'
    if (-not (Test-ResumeInteger $nextIndex) -or [int64]$nextIndex -gt [int]::MaxValue) { Throw-InvalidResumeField 'NextScenarioIndex' 'must be an integer' }
    if ([int64]$nextIndex -lt 0) { Throw-InvalidResumeField 'NextScenarioIndex' 'must not be negative' }
    if ($null -ne $ScenarioCount -and [int64]$nextIndex -gt [int]$ScenarioCount) { Throw-InvalidResumeField 'NextScenarioIndex' "must be within 0..$ScenarioCount" }

    $stageResults = Require-ResumeArray 'StageResults'
    for ($index = 0; $index -lt $stageResults.Count; $index++) {
        Assert-ResumeStageResult -Item $stageResults[$index] -Prefix "StageResults[$index]"
    }
    $scenarioResults = Require-ResumeArray 'ScenarioResults'
    for ($index = 0; $index -lt $scenarioResults.Count; $index++) {
        $item = $scenarioResults[$index]
        foreach ($name in @('Id', 'Mode', 'Status')) {
            if ((Get-AcceptanceObjectProperty $item $name) -isnot [string]) { Throw-InvalidResumeField "ScenarioResults[$index].$name" 'must be a string' }
        }
        if ([string](Get-AcceptanceObjectProperty $item 'Mode') -notin @('TestSafe', 'Live')) { Throw-InvalidResumeField "ScenarioResults[$index].Mode" 'must be TestSafe or Live' }
        if ($mode -eq 'TestSafe' -and [string](Get-AcceptanceObjectProperty $item 'Mode') -ne 'TestSafe') { Throw-InvalidResumeField "ScenarioResults[$index].Mode" 'must not contain Live results in TestSafe state' }
        if ([string](Get-AcceptanceObjectProperty $item 'Status') -ne 'PASS') { Throw-InvalidResumeField "ScenarioResults[$index].Status" 'must be PASS for resumable completed scenarios' }
        if (-not (Test-AcceptanceObjectProperty $item 'Error')) { Throw-InvalidResumeField "ScenarioResults[$index].Error" 'is missing' }
        $scenarioError = Get-AcceptanceObjectProperty $item 'Error'
        if ($null -ne $scenarioError -and $scenarioError -isnot [string]) { Throw-InvalidResumeField "ScenarioResults[$index].Error" 'must be null or a string' }
        if (-not (Test-AcceptanceObjectProperty $item 'Stage')) { Throw-InvalidResumeField "ScenarioResults[$index].Stage" 'is missing' }
        $scenarioStage = Get-AcceptanceObjectProperty $item 'Stage'
        if ($null -ne $scenarioStage) { Assert-ResumeStageResult -Item $scenarioStage -Prefix "ScenarioResults[$index].Stage" }
        elseif ([string](Get-AcceptanceObjectProperty $item 'Status') -eq 'PASS') { Throw-InvalidResumeField "ScenarioResults[$index].Stage" 'must be present for PASS' }
    }
    if ($scenarioResults.Count -ne [int]$nextIndex) { Throw-InvalidResumeField 'ScenarioResults' 'count must equal NextScenarioIndex' }
    $scenarioIds = @($scenarioResults | ForEach-Object { [string](Get-AcceptanceObjectProperty $_ 'Id') })
    if (@($scenarioIds | Select-Object -Unique).Count -ne $scenarioIds.Count) { Throw-InvalidResumeField 'ScenarioResults.Id' 'must be unique' }
    $cleanupReports = Require-ResumeArray 'CleanupReports'
    for ($index = 0; $index -lt $cleanupReports.Count; $index++) {
        $item = $cleanupReports[$index]
        if ((Get-AcceptanceObjectProperty $item 'Scenario') -isnot [string]) { Throw-InvalidResumeField "CleanupReports[$index].Scenario" 'must be a string' }
        if ((Get-AcceptanceObjectProperty $item 'Phase') -isnot [string]) { Throw-InvalidResumeField "CleanupReports[$index].Phase" 'must be a string' }
        $cleanupReport = Get-AcceptanceObjectProperty $item 'Report'
        if ($null -eq $cleanupReport -or (Get-AcceptanceObjectProperty $cleanupReport 'Success') -isnot [bool]) { Throw-InvalidResumeField "CleanupReports[$index].Report.Success" 'must be a boolean' }
        foreach ($name in @('Actions', 'Errors', 'Reports')) {
            $values = Get-AcceptanceObjectProperty $cleanupReport $name
            if ($values -is [string] -or $values -isnot [Array]) { Throw-InvalidResumeField "CleanupReports[$index].Report.$name" 'must be an array' }
            foreach ($value in @($values)) { if ($value -isnot [string]) { Throw-InvalidResumeField "CleanupReports[$index].Report.$name" 'must contain only strings' } }
        }
        Assert-ResumeOwnership -Ownership (Get-AcceptanceObjectProperty $cleanupReport 'Ownership') -Prefix "CleanupReports[$index].Report.Ownership"
    }

    $ownership = Require-ResumeField 'PendingOwnership'
    Assert-ResumeOwnership -Ownership $ownership -Prefix 'PendingOwnership'
    $savedAtValue = Require-ResumeField 'SavedAt'
    if ($savedAtValue -isnot [string] -and $savedAtValue -isnot [datetime]) { Throw-InvalidResumeField 'SavedAt' 'must be a timestamp string' }
    $savedAt = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$savedAtValue, [ref]$savedAt)) { Throw-InvalidResumeField 'SavedAt' 'must be a timestamp string' }
    $errorValue = Require-ResumeField 'Error'
    if ($null -ne $errorValue -and $errorValue -isnot [string]) { Throw-InvalidResumeField 'Error' 'must be null or a string' }

    if ($Paths) {
        $expectedRun = [IO.Path]::GetFullPath((Join-Path $Paths.Runs $runId)).TrimEnd('\')
        if ([IO.Path]::GetFullPath([string]$Paths.Run).TrimEnd('\') -cne $expectedRun) { Throw-InvalidResumeField 'RunId' 'does not match the selected run directory' }
        $expectedBaseline = [IO.Path]::GetFullPath((Join-Path $expectedRun 'baseline')).TrimEnd('\')
        if ([IO.Path]::GetFullPath([string]$Paths.Baseline).TrimEnd('\') -cne $expectedBaseline) { Throw-InvalidResumeField 'RunId' 'does not match the selected baseline directory' }
    }
    return $State
}

function Read-AcceptanceResumeState {
    param([string]$ControlRoot, [string]$Path, [Nullable[int]]$ScenarioCount, [string]$ScenarioFile, [switch]$RequireRunArtifacts)
    if (-not $Path) { $Path = Join-Path ([IO.Path]::GetFullPath($ControlRoot)) 'resume-state.json' }
    $Path = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Resume state not found: $Path" }
    try { $state = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Invalid resume state '$Path': JSON could not be read: $($_.Exception.Message)" }
    [void](Assert-AcceptanceResumeState -State $state -StatePath $Path -ScenarioCount $ScenarioCount)
    if ($ScenarioFile) {
        try { $scenarioDocument = Get-Content -LiteralPath $ScenarioFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "Invalid resume state '$Path': scenario definition could not be read: $($_.Exception.Message)" }
        $mode = [string]$state.Mode
        $orderedScenarios = @($scenarioDocument.scenarioSets.TestSafe)
        if ($mode -eq 'Live') { $orderedScenarios += @($scenarioDocument.scenarioSets.Live) }
        $count = $orderedScenarios.Count
        [void](Assert-AcceptanceResumeState -State $state -StatePath $Path -ScenarioCount $count)
        $scenarioResults = @((Get-AcceptanceObjectProperty -Value $state -Name 'ScenarioResults'))
        for ($index = 0; $index -lt [int](Get-AcceptanceObjectProperty -Value $state -Name 'NextScenarioIndex'); $index++) {
            if ([string](Get-AcceptanceObjectProperty -Value $scenarioResults[$index] -Name 'Id') -cne [string]$orderedScenarios[$index].id) {
                throw "Invalid resume state '$Path': field 'ScenarioResults[$index].Id' does not match scenario order"
            }
        }
    }
    $paths = Get-AcceptanceControlPaths -ControlRoot (Split-Path -Parent $Path) -RunId ([string]$state.RunId)
    [void](Assert-AcceptanceResumeState -State $state -StatePath $Path -ScenarioCount $ScenarioCount -Paths $paths)
    if ($RequireRunArtifacts) {
        foreach ($required in @($paths.Run, $paths.Baseline, (Join-Path $paths.Baseline 'baseline-before.json'))) {
            if (-not (Test-Path -LiteralPath $required)) { throw "Invalid resume state '$Path': RunId does not have required run artifact '$required'" }
        }
    }
    return $state
}

function Import-AcceptanceResumeResults {
    param($State, [Collections.ArrayList]$StageResults, [Collections.ArrayList]$ScenarioResults, [Collections.ArrayList]$CleanupReports)
    foreach ($item in @((Get-AcceptanceObjectProperty -Value $State -Name 'StageResults'))) { [void]$StageResults.Add($item) }
    foreach ($item in @((Get-AcceptanceObjectProperty -Value $State -Name 'ScenarioResults'))) { [void]$ScenarioResults.Add($item) }
    foreach ($item in @((Get-AcceptanceObjectProperty -Value $State -Name 'CleanupReports'))) { [void]$CleanupReports.Add($item) }
}

function Get-AcceptanceResumeTaskSpec {
    param($Paths, [string]$EntryScript, $State)
    $resumeArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$EntryScript`" -Resume -Mode $($State.Mode) -Version $($State.Version) -CredentialTarget `"$($State.CredentialTarget)`" -ControlRoot `"$($Paths.Root)`""
    if ([bool]$State.AcknowledgeRealInstall) { $resumeArguments += " -AcknowledgeRealInstall" }
    $restartAcknowledged = $false
    if ($State -is [Collections.IDictionary]) {
        if ($State.Contains('AcknowledgeRestart')) { $restartAcknowledged = [bool]$State['AcknowledgeRestart'] }
    }
    elseif ($State.PSObject.Properties.Name -contains 'AcknowledgeRestart') { $restartAcknowledged = [bool]$State.AcknowledgeRestart }
    if ($restartAcknowledged) { $resumeArguments += " -AcknowledgeRestart" }
    $systemArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($Paths.ResumeBootstrap)`""
    [PSCustomObject]@{ UserTaskName = $Paths.ResumeUserTask; SystemTaskName = $Paths.ResumeTask; Arguments = $resumeArguments; SystemArguments = $systemArguments; RunId = $State.RunId; NextScenarioIndex = $State.NextScenarioIndex }
}

function Register-AcceptanceResume {
    param(
        $Paths, [string]$EntryScript, $State, [Nullable[int]]$ScenarioCount, [switch]$SkipTaskRegistration,
        [scriptblock]$StateWriter, [scriptblock]$UserTaskRegistrar, [scriptblock]$BootstrapWriter,
        [scriptblock]$SystemTaskRegistrar, [scriptblock]$TaskProbe, [scriptblock]$TaskDeleteInvoker,
        [scriptblock]$FileRemoveInvoker, [scriptblock]$FileExistenceProbe, [scriptblock]$ReportWriter
    )
    $spec = Get-AcceptanceResumeTaskSpec -Paths $Paths -EntryScript $EntryScript -State $State
    if ($SkipTaskRegistration) {
        Write-AcceptanceResumeState -Paths $Paths -State $State -StateWriter $StateWriter
        $persistedState = Read-AcceptanceResumeState -Path $Paths.ResumeState -ScenarioCount $ScenarioCount
        [void](Assert-AcceptanceResumeState -State $persistedState -StatePath $Paths.ResumeState -ScenarioCount $ScenarioCount -Paths $Paths)
        $spec = Get-AcceptanceResumeTaskSpec -Paths $Paths -EntryScript $EntryScript -State $persistedState
        return $spec
    }
    if (-not $TaskProbe) { $TaskProbe = { param($TaskName) Get-AcceptanceScheduledTaskInfo -TaskName $TaskName } }
    if (-not $FileExistenceProbe) { $FileExistenceProbe = { param($Path) Test-Path -LiteralPath $Path -PathType Leaf } }
    if (-not $FileRemoveInvoker) { $FileRemoveInvoker = { param($Path) Remove-Item -LiteralPath $Path -Force -ErrorAction Stop } }
    if (-not $ReportWriter) { $ReportWriter = { param($Path, $Value) Write-AcceptanceJsonFileAtomic -Path $Path -Value $Value } }
    if (-not $UserTaskRegistrar) {
        $UserTaskRegistrar = {
            param($TaskSpec)
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $TaskSpec.Arguments
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
            $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Highest
            Register-ScheduledTask -TaskName $TaskSpec.UserTaskName -Action $action -Trigger $trigger -Principal $principal -Force -ErrorAction Stop | Out-Null
        }
    }
    $bootstrapText = @"
`$ErrorActionPreference = 'SilentlyContinue'
for (`$i = 0; `$i -lt 120; `$i++) {
    schtasks.exe /Run /TN '$($Paths.ResumeUserTask)' | Out-Null
    if (`$LASTEXITCODE -eq 0) { exit 0 }
    Start-Sleep -Seconds 5
}
exit 1
"@
    if (-not $BootstrapWriter) { $BootstrapWriter = { param($Path, $Text) $Text | Set-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop } }
    if (-not $SystemTaskRegistrar) {
        $SystemTaskRegistrar = {
            param($TaskSpec)
            $command = Get-Command schtasks.exe -ErrorAction Stop | Select-Object -First 1
            $taskCommand = "powershell.exe $($TaskSpec.SystemArguments)"
            $result = Invoke-AcceptanceCapturedCommand -FilePath ([string]$command.Source) -ArgumentList @('/Create','/TN',$TaskSpec.SystemTaskName,'/SC','ONSTART','/RU','SYSTEM','/RL','HIGHEST','/TR',$taskCommand,'/F') -TimeoutSec 30
            if ($result.TimedOut -or $null -eq $result.ExitCode -or [int]$result.ExitCode -ne 0) { throw "Failed to create SYSTEM resume bootstrap task" }
        }
    }
    if (-not $TaskDeleteInvoker) {
        $TaskDeleteInvoker = {
            param($TaskName)
            $command = Get-Command schtasks.exe -ErrorAction Stop | Select-Object -First 1
            $result = Invoke-AcceptanceCapturedCommand -FilePath ([string]$command.Source) -ArgumentList @('/Delete','/TN',$TaskName,'/F') -TimeoutSec 30
            if ($result.TimedOut) { throw "Timed out deleting resume task '$TaskName'" }
            if ($null -eq $result.ExitCode -or [int]$result.ExitCode -ne 0) { throw "Failed to delete resume task '$TaskName' (exit $($result.ExitCode))" }
        }
    }

    $report = [ordered]@{
        StartedAt = (Get-Date).ToString('o'); Success = $false; OriginalError = $null
        Steps = [ordered]@{ State = 'Pending'; UserTask = 'Pending'; Bootstrap = 'Pending'; SystemTask = 'Pending'; Verification = 'Pending'; Report = 'Pending' }
        RollbackActions = @(); RollbackErrors = @()
    }
    $rollbackActions = New-Object Collections.ArrayList
    $rollbackErrors = New-Object Collections.ArrayList
    $attemptedUserTask = $false
    $attemptedBootstrap = $false
    $attemptedSystemTask = $false
    try {
        foreach ($taskName in @($spec.UserTaskName, $spec.SystemTaskName)) {
            $preexistingTask = & $TaskProbe $taskName
            if ($preexistingTask -and [bool](Get-AcceptanceObjectProperty $preexistingTask 'Exists')) {
                throw "Refusing to overwrite pre-existing resume task '$taskName'"
            }
        }
        if ([bool](& $FileExistenceProbe $Paths.ResumeBootstrap)) { throw "Refusing to overwrite pre-existing resume bootstrap '$($Paths.ResumeBootstrap)'" }
        if ([bool](& $FileExistenceProbe $Paths.ResumeState)) {
            $existingState = Read-AcceptanceResumeState -Path $Paths.ResumeState -ScenarioCount $ScenarioCount
            if ([string]$existingState.RunId -cne [string]$State.RunId) {
                throw "Refusing to overwrite resume state owned by RunId '$($existingState.RunId)'"
            }
            [void](Assert-AcceptanceResumeState -State $existingState -StatePath $Paths.ResumeState -ScenarioCount $ScenarioCount -Paths $Paths)
        }
        Write-AcceptanceResumeState -Paths $Paths -State $State -StateWriter $StateWriter
        $persistedState = Read-AcceptanceResumeState -Path $Paths.ResumeState -ScenarioCount $ScenarioCount
        [void](Assert-AcceptanceResumeState -State $persistedState -StatePath $Paths.ResumeState -ScenarioCount $ScenarioCount -Paths $Paths)
        $spec = Get-AcceptanceResumeTaskSpec -Paths $Paths -EntryScript $EntryScript -State $persistedState
        $report.Steps.State = 'CreatedAndValidated'
        $attemptedUserTask = $true
        & $UserTaskRegistrar $spec
        $report.Steps.UserTask = 'Created'
        $attemptedBootstrap = $true
        & $BootstrapWriter $Paths.ResumeBootstrap $bootstrapText
        if (-not [bool](& $FileExistenceProbe $Paths.ResumeBootstrap)) { throw 'Resume bootstrap was not created' }
        $report.Steps.Bootstrap = 'Created'
        $attemptedSystemTask = $true
        & $SystemTaskRegistrar $spec
        $report.Steps.SystemTask = 'Created'
        foreach ($expected in @(
            [PSCustomObject]@{ Name = $spec.UserTaskName; Arguments = $spec.Arguments },
            [PSCustomObject]@{ Name = $spec.SystemTaskName; Arguments = $spec.SystemArguments }
        )) {
            $actual = & $TaskProbe $expected.Name
            if (-not $actual -or -not [bool](Get-AcceptanceObjectProperty $actual 'Exists')) { throw "Resume task '$($expected.Name)' is missing after registration" }
            $actualExecutable = [IO.Path]::GetFileName([string](Get-AcceptanceObjectProperty $actual 'Execute'))
            if ($actualExecutable -ine 'powershell.exe') { throw "Resume task '$($expected.Name)' executable does not match the registered state" }
            $actualArguments = [string](Get-AcceptanceObjectProperty $actual 'Arguments')
            if ($actualArguments -cne [string]$expected.Arguments) { throw "Resume task '$($expected.Name)' arguments do not match the registered state" }
        }
        $verifiedState = Read-AcceptanceResumeState -Path $Paths.ResumeState -ScenarioCount $ScenarioCount
        [void](Assert-AcceptanceResumeState -State $verifiedState -StatePath $Paths.ResumeState -ScenarioCount $ScenarioCount -Paths $Paths)
        $report.Steps.Verification = 'Passed'
        $report.Success = $true
        $report.Steps.Report = 'Written'
        $report.CompletedAt = (Get-Date).ToString('o')
        & $ReportWriter $Paths.ResumeRegistrationReport $report
        return $spec
    }
    catch {
        $originalError = $_.Exception.Message
        $report.OriginalError = $originalError
        $report.Success = $false
        foreach ($rollbackTask in @(
            [PSCustomObject]@{ Name = $spec.SystemTaskName; Attempted = $attemptedSystemTask },
            [PSCustomObject]@{ Name = $spec.UserTaskName; Attempted = $attemptedUserTask }
        )) {
            if (-not $rollbackTask.Attempted) { continue }
            $taskName = [string]$rollbackTask.Name
            try {
                $task = & $TaskProbe $taskName
                if ($task -and [bool](Get-AcceptanceObjectProperty $task 'Exists')) {
                    & $TaskDeleteInvoker $taskName
                    $afterDelete = & $TaskProbe $taskName
                    if ($afterDelete -and [bool](Get-AcceptanceObjectProperty $afterDelete 'Exists')) { throw "Resume task '$taskName' still exists after rollback" }
                    [void]$rollbackActions.Add("Deleted task $taskName")
                }
            }
            catch { [void]$rollbackErrors.Add("Task $taskName`: $($_.Exception.Message)") }
        }
        try {
            if ($attemptedBootstrap -and [bool](& $FileExistenceProbe $Paths.ResumeBootstrap)) {
                & $FileRemoveInvoker $Paths.ResumeBootstrap
                if ([bool](& $FileExistenceProbe $Paths.ResumeBootstrap)) { throw 'Resume bootstrap still exists after rollback' }
                [void]$rollbackActions.Add("Deleted bootstrap $($Paths.ResumeBootstrap)")
            }
        }
        catch { [void]$rollbackErrors.Add("Bootstrap: $($_.Exception.Message)") }
        $report.RollbackActions = @($rollbackActions)
        $report.RollbackErrors = @($rollbackErrors)
        $report.CompletedAt = (Get-Date).ToString('o')
        try { & $ReportWriter $Paths.ResumeRegistrationReport $report }
        catch { [void]$rollbackErrors.Add("Registration report: $($_.Exception.Message)"); $report.RollbackErrors = @($rollbackErrors) }
        $suffix = if ($rollbackErrors.Count) { "; rollback/report errors: $($rollbackErrors -join '; ')" } else { '' }
        throw "Resume registration failed: $originalError$suffix"
    }
}

function Get-AcceptanceScheduledTaskInfo {
    param([string]$TaskName)
    $service = New-Object -ComObject 'Schedule.Service'
    $folder = $null
    try {
        $service.Connect()
        $folder = $service.GetFolder('\')
        try {
            $task = $folder.GetTask($TaskName)
            $action = $task.Definition.Actions.Item(1)
            return [PSCustomObject]@{ Exists = $true; Execute = [string]$action.Path; Arguments = [string]$action.Arguments }
        }
        catch {
            # HRESULT 0x80070002 is ERROR_FILE_NOT_FOUND. Permission and RPC
            # failures have different HRESULTs and must remain terminating.
            if ([int]$_.Exception.HResult -eq -2147024894) { return [PSCustomObject]@{ Exists = $false; Execute = $null; Arguments = $null } } # 0x80070002
            throw
        }
    }
    finally {
        if ($folder) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($folder) }
        if ($service) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($service) }
    }
}

function Test-AcceptanceScheduledTaskExists {
    param([string]$TaskName)
    return [bool](Get-AcceptanceScheduledTaskInfo -TaskName $TaskName).Exists
}

function Remove-AcceptanceResume {
    param(
        $Paths, [switch]$KeepState, [scriptblock]$TaskCommandInvoker, [scriptblock]$TaskExistenceProbe,
        [scriptblock]$FileRemoveInvoker, [scriptblock]$FileExistenceProbe, [scriptblock]$ReportWriter
    )
    $entries = New-Object Collections.ArrayList
    $report = [ordered]@{ StartedAt = (Get-Date).ToString('o'); Success = $false; KeepState = [bool]$KeepState; Tasks = @(); State = 'Pending'; Bootstrap = 'Pending'; Error = $null }
    if (-not $TaskCommandInvoker) {
        $TaskCommandInvoker = {
            param([string]$FilePath, [string[]]$Arguments)
            Invoke-AcceptanceCapturedCommand -FilePath $FilePath -ArgumentList $Arguments -TimeoutSec 30
        }
    }
    if (-not $TaskExistenceProbe) { $TaskExistenceProbe = { param([string]$TaskName) Test-AcceptanceScheduledTaskExists -TaskName $TaskName } }
    if (-not $FileExistenceProbe) { $FileExistenceProbe = { param([string]$Path) Test-Path -LiteralPath $Path -PathType Leaf } }
    if (-not $FileRemoveInvoker) { $FileRemoveInvoker = { param([string]$Path) Remove-Item -LiteralPath $Path -Force -ErrorAction Stop } }
    if (-not $ReportWriter) { $ReportWriter = { param($Path, $Value) Write-AcceptanceJsonFileAtomic -Path $Path -Value $Value } }
    $stateExisted = $false
    $stateBytes = $null
    $stateHash = $null
    $operationError = $null
    $reportError = $null
    try {
        $stateExisted = [bool](& $FileExistenceProbe $Paths.ResumeState)
        if ($stateExisted) {
            $stateBytes = [IO.File]::ReadAllBytes($Paths.ResumeState)
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $stateHash = [BitConverter]::ToString($sha.ComputeHash($stateBytes)).Replace('-', '') }
            finally { $sha.Dispose() }
        }
        foreach ($taskName in @($Paths.ResumeTask, $Paths.ResumeUserTask)) {
            if (-not [bool](& $TaskExistenceProbe $taskName)) {
                [void]$entries.Add([ordered]@{ TaskName = $taskName; Status = 'Missing' })
                continue
            }
            $schtasks = Get-Command schtasks.exe -ErrorAction Stop | Select-Object -First 1
            $delete = & $TaskCommandInvoker ([string]$schtasks.Source) @('/Delete', '/TN', $taskName, '/F')
            if ($delete.TimedOut) { throw "Timed out deleting resume task '$taskName'" }
            if ($null -eq $delete.ExitCode -or [int]$delete.ExitCode -ne 0) {
                throw "Failed to delete resume task '$taskName' (exit $($delete.ExitCode)): $([string]$delete.StdErr)"
            }
            if ([bool](& $TaskExistenceProbe $taskName)) { throw "Resume task '$taskName' still exists after schtasks.exe reported success" }
            [void]$entries.Add([ordered]@{ TaskName = $taskName; Status = 'Deleted'; DeleteExitCode = [int]$delete.ExitCode })
        }
        $bootstrap = [string]$Paths.ResumeBootstrap
        if ([bool](& $FileExistenceProbe $bootstrap)) {
            & $FileRemoveInvoker $bootstrap
            if ([bool](& $FileExistenceProbe $bootstrap)) { throw "Resume bootstrap '$bootstrap' still exists after deletion" }
            $report.Bootstrap = 'Deleted'
        }
        else { $report.Bootstrap = 'Missing' }
        if ($KeepState) { $report.State = if ($stateExisted) { 'Kept' } else { 'Missing' } }
        elseif ([bool](& $FileExistenceProbe $Paths.ResumeState)) {
            & $FileRemoveInvoker $Paths.ResumeState
            if ([bool](& $FileExistenceProbe $Paths.ResumeState)) { throw "Resume state '$($Paths.ResumeState)' still exists after deletion" }
            $report.State = 'Deleted'
        }
        else { $report.State = 'Missing' }
        $report.Success = $true
    }
    catch {
        $report.Error = $_.Exception.Message
        $operationError = $_.Exception.Message
        $report.Success = $false
    }
    $report.Tasks = @($entries)
    $report.CompletedAt = (Get-Date).ToString('o')
    try { & $ReportWriter $Paths.ResumeCleanupReport $report }
    catch {
        $reportError = $_.Exception.Message
        $report.Success = $false
        if (-not $KeepState -and $stateExisted -and -not [bool](& $FileExistenceProbe $Paths.ResumeState)) {
            try {
                if ($null -eq $stateBytes) { throw 'Original resume state bytes were unavailable' }
                [IO.File]::WriteAllBytes($Paths.ResumeState, $stateBytes)
                if (-not [bool](& $FileExistenceProbe $Paths.ResumeState)) { throw 'Restored resume state is still missing' }
                if ((Get-FileHash -LiteralPath $Paths.ResumeState -Algorithm SHA256 -ErrorAction Stop).Hash -cne $stateHash) { throw 'Restored resume state hash differs from the original' }
            }
            catch { $reportError += "; failed to restore resume state: $($_.Exception.Message)" }
        }
    }
    if ($stateBytes) { [Array]::Clear($stateBytes, 0, $stateBytes.Length) }
    if ($operationError -or $reportError) {
        $parts = @($operationError, $(if ($reportError) { "cleanup report write failed: $reportError" })) | Where-Object { $_ }
        throw ($parts -join '; ')
    }
    return [PSCustomObject]$report
}
