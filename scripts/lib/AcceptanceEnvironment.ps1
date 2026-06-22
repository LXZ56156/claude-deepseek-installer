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
        Baseline = [IO.Path]::GetFullPath((Join-Path $ControlRoot "runs\$RunId\baseline"))
        Runs = [IO.Path]::GetFullPath((Join-Path $ControlRoot "runs"))
        Run = [IO.Path]::GetFullPath((Join-Path $ControlRoot "runs\$RunId"))
        ResumeState = [IO.Path]::GetFullPath((Join-Path $ControlRoot "resume-state.json"))
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
        $claudeConfigRoot = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.claude')).TrimEnd('\')
        if ($fullRoot.TrimEnd('\') -eq $claudeConfigRoot) {
            $settingsItem = Join-Path $fullRoot 'settings.json'
            if (Test-Path -LiteralPath $settingsItem -PathType Leaf) { & $addFile (Get-Item -LiteralPath $settingsItem -Force) 'File' }
            continue
        }
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
            ) -TimeoutSec 60
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
        try { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop; [void]$actions.Add("Stopped process $($process.ProcessId) $($process.Name)") }
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

function Write-AcceptanceResumeState {
    param($Paths, $State)
    $State | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Paths.ResumeState -Encoding UTF8
}

function Read-AcceptanceResumeState {
    param([string]$ControlRoot)
    $path = Join-Path ([IO.Path]::GetFullPath($ControlRoot)) "resume-state.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Resume state not found: $path" }
    Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Import-AcceptanceResumeResults {
    param($State, [Collections.ArrayList]$StageResults, [Collections.ArrayList]$ScenarioResults, [Collections.ArrayList]$CleanupReports)
    foreach ($item in @($State.StageResults)) { [void]$StageResults.Add($item) }
    foreach ($item in @($State.ScenarioResults)) { [void]$ScenarioResults.Add($item) }
    foreach ($item in @($State.CleanupReports)) { [void]$CleanupReports.Add($item) }
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
    [PSCustomObject]@{ UserTaskName = $Paths.ResumeUserTask; SystemTaskName = $Paths.ResumeTask; Arguments = $resumeArguments; RunId = $State.RunId; NextScenarioIndex = $State.NextScenarioIndex }
}

function Register-AcceptanceResume {
    param($Paths, [string]$EntryScript, $State, [switch]$SkipTaskRegistration)
    Write-AcceptanceResumeState -Paths $Paths -State $State
    $spec = Get-AcceptanceResumeTaskSpec -Paths $Paths -EntryScript $EntryScript -State $State
    if ($SkipTaskRegistration) { return $spec }
    $resumeArguments = $spec.Arguments
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
    return $spec
}

function Remove-AcceptanceResume {
    param($Paths, [switch]$KeepState)
    $schtasks = Get-Command schtasks.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($schtasks) {
        # Missing tasks are the normal no-resume case; capture the nonzero exit without
        # allowing native stderr to become a terminating PowerShell error.
        [void](Invoke-AcceptanceCapturedCommand -FilePath ([string]$schtasks.Source) -ArgumentList @('/Delete', '/TN', $Paths.ResumeTask, '/F') -TimeoutSec 30)
        [void](Invoke-AcceptanceCapturedCommand -FilePath ([string]$schtasks.Source) -ArgumentList @('/Delete', '/TN', $Paths.ResumeUserTask, '/F') -TimeoutSec 30)
    }
    if (-not $KeepState) { Remove-Item -LiteralPath $Paths.ResumeState -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath (Join-Path $Paths.Root "resume-bootstrap.ps1") -Force -ErrorAction SilentlyContinue
}
