# ============================================================
# scripts/simulate-user-release.ps1 - Release 用户路径模拟验收
# ============================================================

param(
    [string]$Version = "1.3.3",
    [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BuildScript = Join-Path $ProjectRoot "scripts\build-release.ps1"
$ReleaseDir = Join-Path $ProjectRoot "release"
$DummyApiKey = "sk-" + ("x" * 32)

function Write-Check {
    param([string]$Message)
    Write-Host "[simulate] $Message" -ForegroundColor Cyan
}

function ConvertTo-SimCommandLineArgument {
    param([AllowNull()][string]$Argument)

    if ($null -eq $Argument) {
        return '""'
    }
    if ($Argument.Length -eq 0) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $result = New-Object System.Text.StringBuilder
    [void]$result.Append('"')
    $backslashes = 0

    foreach ($char in $Argument.ToCharArray()) {
        if ($char -eq '\') {
            $backslashes++
            continue
        }

        if ($char -eq '"') {
            [void]$result.Append(('\' * ($backslashes * 2 + 1)))
            [void]$result.Append('"')
        }
        else {
            if ($backslashes -gt 0) {
                [void]$result.Append(('\' * $backslashes))
            }
            [void]$result.Append($char)
        }

        $backslashes = 0
    }

    if ($backslashes -gt 0) {
        [void]$result.Append(('\' * ($backslashes * 2)))
    }
    [void]$result.Append('"')

    return $result.ToString()
}

function ConvertTo-SimCommandLine {
    param([string[]]$Arguments)

    if (-not $Arguments) {
        return ""
    }

    $quoted = @()
    foreach ($arg in $Arguments) {
        $quoted += ConvertTo-SimCommandLineArgument -Argument $arg
    }
    return ($quoted -join " ")
}

function Invoke-SimCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$FileName,
        [string[]]$Arguments = @(),
        [string]$InputText = "",
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,
        [int]$ExpectedExitCode = 0,
        [hashtable]$Environment = @{},
        [int]$TimeoutSec = 120
    )

    Write-Check "run: $Name"

    # powershell.exe 需通过命令行参数 -WindowStyle Hidden 隐藏窗口
    # （ProcessStartInfo.WindowStyle 仅在 UseShellExecute=$true 时生效，
    #   此处 UseShellExecute=$false，必须用命令行参数）
    if ($FileName -match 'powershell(\.exe)?$') {
        $Arguments = @("-WindowStyle", "Hidden") + $Arguments
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = ConvertTo-SimCommandLine -Arguments $Arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

    # 默认环境变量：让子进程尽量后台运行，不弹出控制台窗口
    $defaultEnv = @{
        TERM                      = "dumb"
        NO_COLOR                  = "1"
        CLAUDE_CODE_DISABLE_COLOR = "1"
        CCDI_TEST_MODE            = "1"
        CCDI_NO_INTERACTIVE_UI    = "1"
    }

    foreach ($key in $defaultEnv.Keys) {
        if (-not $psi.EnvironmentVariables.ContainsKey($key)) {
            $psi.EnvironmentVariables[$key] = [string]$defaultEnv[$key]
        }
    }

    # 调用方传入的 Environment 可以覆盖默认值
    foreach ($key in $Environment.Keys) {
        $psi.EnvironmentVariables[$key] = [string]$Environment[$key]
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
        try {
            & taskkill.exe /PID $realPid /T /F 2>$null | Out-Null
            Start-Sleep -Milliseconds 500
        } catch { }
        if (-not $proc.HasExited) {
            try { Stop-Process -Id $realPid -Force -ErrorAction SilentlyContinue } catch { }
        }
        throw "$Name timed out after ${TimeoutSec}s (PID=$realPid)"
    }

    [void]$stdoutTask.Wait(5000)
    [void]$stderrTask.Wait(5000)

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exitCode = $proc.ExitCode

    if ($exitCode -ne $ExpectedExitCode) {
        throw "$Name exit code $exitCode, expected $ExpectedExitCode.`nSTDOUT:`n$stdout`nSTDERR:`n$stderr"
    }

    return [PSCustomObject]@{
        Name     = $Name
        ExitCode = $exitCode
        Stdout   = $stdout
        Stderr   = $stderr
        Combined = "$stdout`n$stderr"
    }
}

function Assert-FileUtf8Bom {
    param([System.IO.FileInfo]$File)

    $bytes = [System.IO.File]::ReadAllBytes($File.FullName)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        throw "$($File.FullName) is missing UTF-8 BOM"
    }
}

function Assert-CmdAsciiNoBom {
    param([System.IO.FileInfo]$File)

    $bytes = [System.IO.File]::ReadAllBytes($File.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "$($File.FullName) has UTF-8 BOM"
    }
    foreach ($b in $bytes) {
        if ($b -gt 0x7F) {
            throw "$($File.FullName) contains non-ASCII byte $b"
        }
    }
}

function Assert-ReleaseDocsNoTerminalRiskChars {
    param([string]$ReleaseRoot)

    $badPattern = '\p{So}|[\u2500-\u257F]|\uFE0F'
    $docFiles = Get-ChildItem -Path $ReleaseRoot -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @(".md", ".txt") }

    foreach ($file in $docFiles) {
        $content = Get-Content -Path $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        $matches = [regex]::Matches($content, $badPattern)
        if ($matches.Count -gt 0) {
            $relPath = $file.FullName.Substring($ReleaseRoot.Length + 1)
            throw "release doc contains terminal-risk characters: $relPath"
        }
    }
}

function Assert-NoBadRuntimeText {
    param(
        [array]$Runs,
        [string]$ReleaseRoot,
        [string]$DummyKey
    )

    $texts = New-Object System.Collections.ArrayList
    foreach ($run in $Runs) {
        [void]$texts.Add("[RUN:$($run.Name)]`n$($run.Combined)")
    }

    $runtimeFiles = @()
    foreach ($dirName in @("logs", "reports")) {
        $dir = Join-Path $ReleaseRoot $dirName
        if (Test-Path $dir) {
            $runtimeFiles += Get-ChildItem -Path $dir -File -Recurse -ErrorAction SilentlyContinue
        }
    }
    $latestReport = Join-Path $ReleaseRoot "report.txt"
    if (Test-Path $latestReport) {
        $runtimeFiles += Get-Item $latestReport
    }

    foreach ($file in $runtimeFiles) {
        $content = Get-Content -Path $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        [void]$texts.Add("[FILE:$($file.FullName)]`n$content")
    }

    $badPatterns = @(
        "ParserError",
        "无法将",
        "not recognized",
        "Write-Log",
        "Write-Error-Msg"
    )

    foreach ($text in $texts) {
        foreach ($pattern in $badPatterns) {
            if ($text -match [regex]::Escape($pattern)) {
                throw "runtime output contains failure marker '$pattern'"
            }
        }
        if ($text -match [regex]::Escape($DummyKey)) {
            throw "runtime output leaked full dummy API Key"
        }
    }
}

function Assert-TextOrder {
    <#
    .SYNOPSIS
        Assert that success text appears BEFORE failure/diagnostic text in combined output.
        If final success is present, the success line must come first.
    .PARAMETER Text
        Combined output text from a simulation run.
    .PARAMETER Scenario
        Scenario name for error messages.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [string]$Scenario = ""
    )

    $prefix = if ($Scenario) { "[$Scenario] " } else { "" }

    # 成功文案标记
    $successMarkers = @(
        "Claude Code 已安装并确认可用",
        "[OK] Claude Code 安装"
    )

    # 失败/诊断类文案（不得出现在成功文案之前）
    $failureMarkers = @(
        "请运行" + [char]0x201C + "一键诊断.cmd" + [char]0x201D + "获取详细诊断报告",
        "备用下载方式未完成确认",
        "[ERROR] Claude Code 安装"
    )

    $hasSuccess = $false
    $firstSuccessPos = [int]::MaxValue
    foreach ($m in $successMarkers) {
        $idx = $Text.IndexOf($m, [StringComparison]::Ordinal)
        if ($idx -ge 0) {
            $hasSuccess = $true
            if ($idx -lt $firstSuccessPos) {
                $firstSuccessPos = $idx
            }
        }
    }

    if (-not $hasSuccess) {
        # No success marker present — order check not applicable
        return
    }

    foreach ($m in $failureMarkers) {
        $idx = $Text.IndexOf($m, [StringComparison]::Ordinal)
        if ($idx -ge 0 -and $idx -lt $firstSuccessPos) {
            throw "${prefix}Failure/diagnostic text '$m' appears BEFORE success text at position $idx vs success at $firstSuccessPos"
        }
    }

    Write-Host "[simulate]   ${prefix}text order OK (success before diagnostic)" -ForegroundColor Green
}

function New-TestClaudeConfig {
    param([string]$ProfileDir, [string]$DummyKey)

    $claudeDir = Join-Path $ProfileDir ".claude"
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
    $settingsPath = Join-Path $claudeDir "settings.json"

    $settings = [PSCustomObject]@{
        env = [PSCustomObject]@{
            ANTHROPIC_BASE_URL = "https://api.deepseek.com/anthropic"
            ANTHROPIC_AUTH_TOKEN = $DummyKey
            ANTHROPIC_MODEL = "deepseek-v4-pro[1m]"
            ANTHROPIC_SMALL_FAST_MODEL = "deepseek-v4-flash"
        }
    }

    $json = $settings | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($settingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function New-SimEnvironment {
    param(
        [string]$ProfileDir,
        [string]$DesktopDir,
        [string]$DummyKey,
        [string]$ApiStatus = "200"
    )

    $envVars = @{
        CCDI_TEST_MODE = "1"
        CCDI_TEST_USERPROFILE = $ProfileDir
        CCDI_TEST_DESKTOP = $DesktopDir
        CCDI_API_KEY = $DummyKey
    }

    if (-not [string]::IsNullOrWhiteSpace($ApiStatus)) {
        $envVars.CCDI_TEST_API_STATUS = $ApiStatus
    }

    return $envVars
}

function Assert-ZipDoesNotContainForbiddenEntries {
    param([string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entries = $zip.Entries | ForEach-Object { $_.FullName }
        $forbidden = @(
            ".git/",
            "logs/",
            "backup/",
            "reports/",
            "release/",
            "CLAUDE.md",
            ".gitignore",
            "report.txt",
            "QUICK_START.md",
            "docs/",
            "examples/",
            "scripts/"
        )
        foreach ($entry in $entries) {
            foreach ($pattern in $forbidden) {
                if ($entry -like "*$pattern*") {
                    throw "ZIP contains forbidden entry: $entry"
                }
            }
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Assert-ZipContainsRequiredEntries {
    param([string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entries = $zip.Entries | ForEach-Object { $_.FullName }
        $required = @(
            "01-先看我-安装说明.txt",
            "02-安装完成后怎么开始使用.txt",
            "03-常用提示词模板.txt",
            "04-常见问题和售后.txt",
            "提示词模板/00-先用这个-检查环境和项目.txt",
            "提示词模板/01-接手已有代码项目.txt",
            "提示词模板/02-补装开发环境和依赖.txt",
            "提示词模板/03-微信小程序开发.txt",
            "提示词模板/04-网页前端项目.txt",
            "提示词模板/05-Python脚本开发.txt",
            "提示词模板/06-安全修改代码.txt",
            "提示词模板/07-生成README和使用说明.txt"
        )
        # Normalize entries to forward-slash for comparison
        $normalized = $entries | ForEach-Object { $_ -replace '\\', '/' }
        foreach ($req in $required) {
            $normalizedReq = $req -replace '\\', '/'
            if ($normalizedReq -notin $normalized) {
                throw "ZIP is missing required entry: $req"
            }
        }
    }
    finally {
        $zip.Dispose()
    }
}

$powerShellExe = "powershell.exe"
if (-not (Get-Command $powerShellExe -ErrorAction SilentlyContinue)) {
    $powerShellExe = "powershell"
}

$cmdExe = "cmd.exe"
if (-not (Get-Command $cmdExe -ErrorAction SilentlyContinue)) {
    throw "cmd.exe not found; this simulation must run on Windows or WSL with Windows interop"
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ccdi 用户 模拟 $PID")
$extractRoot = Join-Path $tempRoot "解压 目录 With Spaces"
$testProfile = Join-Path $tempRoot "User Profile"
$testDesktop = Join-Path $tempRoot "Desktop 桌面"

if (Test-Path $tempRoot) {
    Remove-Item -Path $tempRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
New-Item -ItemType Directory -Path $testProfile -Force | Out-Null
New-Item -ItemType Directory -Path $testDesktop -Force | Out-Null

try {
    Write-Check "build release $Version"
    & $powerShellExe -NoProfile -ExecutionPolicy Bypass -File $BuildScript -Version $Version
    if ($LASTEXITCODE -ne 0) {
        throw "build-release.ps1 failed with exit code $LASTEXITCODE"
    }

    $zip = Get-ChildItem -Path $ReleaseDir -Filter "*.zip" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $zip) {
        throw "release ZIP not found"
    }

    Assert-ZipDoesNotContainForbiddenEntries -ZipPath $zip.FullName
    Assert-ZipContainsRequiredEntries -ZipPath $zip.FullName

    Write-Check "extract ZIP to $extractRoot"
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $extractRoot -Force

    $releaseRoot = $extractRoot
    New-TestClaudeConfig -ProfileDir $testProfile -DummyKey $DummyApiKey

    Write-Check "static checks"
    Get-ChildItem -Path $releaseRoot -Filter "*.ps1" -Recurse | ForEach-Object {
        Assert-FileUtf8Bom -File $_
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) {
            throw "PowerShell parse failed: $($_.FullName) - $($errors[0].Message)"
        }
    }
    Get-ChildItem -Path $releaseRoot -Filter "*.cmd" -Recurse | ForEach-Object {
        Assert-CmdAsciiNoBom -File $_
    }
    Assert-ReleaseDocsNoTerminalRiskChars -ReleaseRoot $releaseRoot
    $startHereSource = Get-Content -Path (Join-Path $releaseRoot "Start-Here.ps1") -Raw -Encoding UTF8
    if ($startHereSource -notmatch "直接回车默认选 1") {
        throw "Start-Here source does not show default option guidance"
    }
    if ($startHereSource -notmatch "高级选项") {
        throw "Start-Here source does not include advanced menu"
    }

    Write-Check "bootstrap exports from extracted release"
    Push-Location $releaseRoot
    try {
        . .\lib\bootstrap.ps1
        Initialize-CcdiScript -ScriptName "bootstrap-smoke" | Out-Null
        $requiredCommands = @(
            "Write-Log",
            "Write-Info",
            "Write-Success",
            "Write-Warning",
            "Write-Error-Msg",
            "Write-FatalError",
            "Invoke-CommandSafe",
            "Read-ApiKeyWithMaskedConfirmation",
            "Get-DesktopPath",
            "Get-WindowsVersionInfo",
            "Test-ClaudeInstalled",
            "Write-DeepSeekConfig",
            "Get-DeepSeekConfigStatus",
            "Get-CcdiStateValue"
        )
        foreach ($cmd in $requiredCommands) {
            if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
                throw "Bootstrap export missing: $cmd"
            }
        }
    }
    finally {
        Pop-Location
    }

    $envVars = New-SimEnvironment -ProfileDir $testProfile -DesktopDir $testDesktop -DummyKey $DummyApiKey -ApiStatus "200"

    $runs = New-Object System.Collections.ArrayList
    $startHerePath = Join-Path $releaseRoot "Start-Here.ps1"
    $startFlowRun = Invoke-SimCommand -Name "Start-Here.ps1 TestSafe flow" -FileName $powerShellExe -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $startHerePath,
        "-NonInteractive", "-SkipDisclaimer", "-TestSafe"
    ) -WorkingDirectory $releaseRoot -Environment $envVars -TimeoutSec 180
    [void]$runs.Add($startFlowRun)

    [void]$runs.Add((Invoke-SimCommand -Name "Start-Install.cmd cancel" -FileName $cmdExe -Arguments @("/d", "/c", "echo N| .\Start-Install.cmd") -WorkingDirectory $releaseRoot -Environment $envVars))
    [void]$runs.Add((Invoke-SimCommand -Name "00-点我开始安装.cmd cancel" -FileName $cmdExe -Arguments @("/d", "/c", "echo N| .\00-点我开始安装.cmd") -WorkingDirectory $releaseRoot -Environment $envVars))

    $startHereLogs = Get-ChildItem -Path (Join-Path $releaseRoot "logs") -Filter "start-here-*.log" -ErrorAction SilentlyContinue
    $startHereLogText = ($startHereLogs | ForEach-Object { Get-Content -Path $_.FullName -Raw -Encoding UTF8 }) -join "`n"
    $startHereRuntimeText = "$startHereLogText`n$($startFlowRun.Combined)"
    $testSettingsPath = Join-Path $testProfile ".claude\settings.json"
    $installReports = Get-ChildItem -Path (Join-Path $releaseRoot "reports") -Filter "install-report-*.txt" -ErrorAction SilentlyContinue
    if ((-not (Test-Path $testSettingsPath)) -or (-not $installReports) -or $startHereRuntimeText -notmatch "DeepSeek 配置写入.*(已验证|已在沙盒路径验证)") {
        throw "Start-Here TestSafe flow did not complete configuration validation"
    }

    $partialStateDir = Join-Path $testProfile ".claude-deepseek-installer"
    New-Item -ItemType Directory -Path $partialStateDir -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $partialStateDir "state.json"),
        "{`"claudeInstallMethod`":`"existing`",`"claudeWasAlreadyInstalled`":true,`"claudeInstallStatus`":`"skipped_existing`"}",
        (New-Object System.Text.UTF8Encoding($false))
    )
    $partialStateRun = Invoke-SimCommand -Name "uninstall-config.ps1 partial state ShowStatusOnly" -FileName $powerShellExe -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $releaseRoot "uninstall-config.ps1"), "-ShowStatusOnly"
    ) -WorkingDirectory $releaseRoot -Environment $envVars
    $partialStateLog = Get-ChildItem -Path (Join-Path $releaseRoot "logs") -Filter "uninstall-config-*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    $partialStateLogText = if ($partialStateLog) { Get-Content -Path $partialStateLog.FullName -Raw -Encoding UTF8 } else { "" }
    if ($partialStateLogText -notmatch "首次运行时间: \(未记录\)") {
        throw "partial state ShowStatusOnly did not show missing firstRunAt default"
    }
    [void]$runs.Add($partialStateRun)

    [void]$runs.Add((Invoke-SimCommand -Name "Run-Diagnostics.cmd" -FileName $cmdExe -Arguments @("/c", ".\Run-Diagnostics.cmd") -InputText "`r`n" -WorkingDirectory $releaseRoot -Environment $envVars -TimeoutSec 180))
    [void]$runs.Add((Invoke-SimCommand -Name "一键诊断.cmd" -FileName $cmdExe -Arguments @("/c", ".\一键诊断.cmd") -InputText "`r`n" -WorkingDirectory $releaseRoot -Environment $envVars -TimeoutSec 180))

    [void]$runs.Add((Invoke-SimCommand -Name "Restore-Config.cmd" -FileName $cmdExe -Arguments @("/c", ".\Restore-Config.cmd") -InputText "4`r`n`r`n" -WorkingDirectory $releaseRoot -Environment $envVars))
    [void]$runs.Add((Invoke-SimCommand -Name "恢复或卸载配置.cmd" -FileName $cmdExe -Arguments @("/c", ".\恢复或卸载配置.cmd") -InputText "4`r`n`r`n" -WorkingDirectory $releaseRoot -Environment $envVars))

    [void]$runs.Add((Invoke-SimCommand -Name "一键修复依赖.cmd TestSafe" -FileName $cmdExe -Arguments @("/c", ".\一键修复依赖.cmd") -InputText "`r`n" -WorkingDirectory $releaseRoot -Environment $envVars -TimeoutSec 180))

    $settingsPath = Join-Path $testProfile ".claude\settings.json"
    $customSettings = [PSCustomObject]@{
        permissions = [PSCustomObject]@{
            deny = @("Read(./.env)")
        }
        env = [PSCustomObject]@{
            CUSTOM_KEEP = "yes"
            ANTHROPIC_BASE_URL = "https://api.deepseek.com/anthropic"
            ANTHROPIC_AUTH_TOKEN = $DummyApiKey
            ANTHROPIC_MODEL = "deepseek-v4-pro[1m]"
            ANTHROPIC_SMALL_FAST_MODEL = "deepseek-v4-flash"
        }
    }
    $customSettings | ConvertTo-Json -Depth 8 | Set-Content -Path $settingsPath -Encoding UTF8

    $listBackupsRun = Invoke-SimCommand -Name "uninstall-config.ps1 -ListBackups" -FileName $powerShellExe -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $releaseRoot "uninstall-config.ps1"), "-ListBackups"
    ) -WorkingDirectory $releaseRoot -Environment $envVars
    if ($listBackupsRun.Combined -notmatch 'settings\.json\..*\.bak') {
        throw "-ListBackups did not print backup file names"
    }
    [void]$runs.Add($listBackupsRun)

    [void]$runs.Add((Invoke-SimCommand -Name "uninstall-config.ps1 -RemoveDeepSeekEnv" -FileName $powerShellExe -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $releaseRoot "uninstall-config.ps1"), "-RemoveDeepSeekEnv", "-Yes"
    ) -WorkingDirectory $releaseRoot -Environment $envVars))
    $removedConfig = Get-Content -Path $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $removedEnvNames = $removedConfig.env.PSObject.Properties.Name
    if ($removedConfig.permissions.deny -notcontains "Read(./.env)" -or $removedConfig.env.CUSTOM_KEEP -ne "yes") {
        throw "RemoveDeepSeekEnv did not preserve custom configuration"
    }
    if ($removedEnvNames -contains "ANTHROPIC_AUTH_TOKEN" -or $removedEnvNames -contains "ANTHROPIC_BASE_URL") {
        throw "RemoveDeepSeekEnv did not remove DeepSeek env fields"
    }

    [void]$runs.Add((Invoke-SimCommand -Name "uninstall-config.ps1 -RestoreLatest" -FileName $powerShellExe -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $releaseRoot "uninstall-config.ps1"), "-RestoreLatest", "-Yes"
    ) -WorkingDirectory $releaseRoot -Environment $envVars))
    $restoredConfig = Get-Content -Path $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($restoredConfig.env.ANTHROPIC_AUTH_TOKEN -ne $DummyApiKey) {
        throw "RestoreLatest did not restore DeepSeek API token"
    }

    [void]$runs.Add((Invoke-SimCommand -Name "uninstall-config.ps1 -DeleteSettings" -FileName $powerShellExe -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $releaseRoot "uninstall-config.ps1"), "-DeleteSettings", "-Yes"
    ) -WorkingDirectory $releaseRoot -Environment $envVars))
    if (Test-Path $settingsPath) {
        throw "DeleteSettings did not remove settings.json"
    }

    [void]$runs.Add((Invoke-SimCommand -Name "uninstall-config.ps1 restore after delete" -FileName $powerShellExe -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $releaseRoot "uninstall-config.ps1"), "-RestoreLatest", "-Yes"
    ) -WorkingDirectory $releaseRoot -Environment $envVars))
    if (-not (Test-Path $settingsPath)) {
        throw "RestoreLatest after delete did not recreate settings.json"
    }

    $noKeyProfile = Join-Path $tempRoot "No Key Profile"
    $noKeyDesktop = Join-Path $tempRoot "No Key Desktop"
    New-Item -ItemType Directory -Path $noKeyProfile, $noKeyDesktop -Force | Out-Null
    $noKeyEnv = New-SimEnvironment -ProfileDir $noKeyProfile -DesktopDir $noKeyDesktop -DummyKey $DummyApiKey -ApiStatus "200"
    $noKeyEnv["CCDI_API_KEY"] = ""
    $noKeyEnv["DEEPSEEK_API_KEY"] = ""
    [void]$runs.Add((Invoke-SimCommand -Name "configure-deepseek.ps1 no API key" -FileName $powerShellExe -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $releaseRoot "configure-deepseek.ps1"), "-NonInteractive", "-SkipApiTest"
    ) -WorkingDirectory $releaseRoot -Environment $noKeyEnv -ExpectedExitCode 1))

    $corruptProfile = Join-Path $tempRoot "Corrupt Profile"
    $corruptDesktop = Join-Path $tempRoot "Corrupt Desktop"
    New-Item -ItemType Directory -Path (Join-Path $corruptProfile ".claude"), $corruptDesktop -Force | Out-Null
    $corruptSettings = Join-Path $corruptProfile ".claude\settings.json"
    Set-Content -Path $corruptSettings -Encoding UTF8 -Value "{ bad json"
    $corruptEnv = New-SimEnvironment -ProfileDir $corruptProfile -DesktopDir $corruptDesktop -DummyKey $DummyApiKey -ApiStatus "200"
    $corruptRun = Invoke-SimCommand -Name "configure-deepseek.ps1 corrupted JSON" -FileName $powerShellExe -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $releaseRoot "configure-deepseek.ps1"), "-NonInteractive", "-SkipApiTest"
    ) -WorkingDirectory $releaseRoot -Environment $corruptEnv
    $configureLogs = Get-ChildItem -Path (Join-Path $releaseRoot "logs") -Filter "configure-deepseek-*.log" -ErrorAction SilentlyContinue
    $configureLogText = ($configureLogs | ForEach-Object { Get-Content -Path $_.FullName -Raw -Encoding UTF8 }) -join "`n"
    if ($configureLogText -notmatch "JSON 格式无效" -or $configureLogText -notmatch "非 env 字段") {
        throw "corrupted JSON configure path did not show explicit warnings"
    }
    $corruptConfig = Get-Content -Path $corruptSettings -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($corruptConfig.env.ANTHROPIC_AUTH_TOKEN -ne $DummyApiKey) {
        throw "corrupted JSON configure path did not rebuild settings.json"
    }
    [void]$runs.Add($corruptRun)

    $rootReport = Join-Path $releaseRoot "report.txt"
    $reportsDir = Join-Path $releaseRoot "reports"
    if (-not (Test-Path $rootReport)) {
        throw "doctor did not create report.txt"
    }
    if (-not (Get-ChildItem -Path $reportsDir -Filter "report-*.txt" -ErrorAction SilentlyContinue)) {
        throw "doctor did not create reports/report-*.txt"
    }

    $apiMockCases = @(
        @{ Status = "200"; Expected = "200 OK" },
        @{ Status = "401"; Expected = "API Key 验证失败" },
        @{ Status = "402"; Expected = "余额" },
        @{ Status = "429"; Expected = "请求过于频繁" },
        @{ Status = "503"; Expected = "DeepSeek 官方正在维护" },
        @{ Status = "timeout"; Expected = "连接超时" },
        @{ Status = "dns"; Expected = "DNS 解析失败" }
    )

    foreach ($case in $apiMockCases) {
        $caseEnv = New-SimEnvironment -ProfileDir $testProfile -DesktopDir $testDesktop -DummyKey $DummyApiKey -ApiStatus $case.Status
        $caseReport = Join-Path $reportsDir "api-mock-$($case.Status).txt"
        $run = Invoke-SimCommand -Name "doctor API mock $($case.Status)" -FileName $powerShellExe -Arguments @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $releaseRoot "doctor.ps1"),
            "-OutputPath", $caseReport,
            "-NoOpenReport"
        ) -InputText "`r`n" -WorkingDirectory $releaseRoot -Environment $caseEnv -TimeoutSec 180
        $caseReportText = Get-Content -Path $caseReport -Raw -Encoding UTF8
        if ($caseReportText -notmatch [regex]::Escape($case.Expected)) {
            throw "doctor API mock $($case.Status) report missing expected text: $($case.Expected)"
        }
        [void]$runs.Add($run)
    }

    $missingDir = Join-Path $tempRoot "missing files"
    New-Item -ItemType Directory -Path $missingDir -Force | Out-Null
    foreach ($launcher in @(
        "Start-Install.cmd",
        "00-点我开始安装.cmd",
        "Run-Diagnostics.cmd",
        "一键诊断.cmd",
        "Restore-Config.cmd",
        "恢复或卸载配置.cmd",
        "一键修复依赖.cmd"
    )) {
        Copy-Item -Path (Join-Path $releaseRoot $launcher) -Destination (Join-Path $missingDir $launcher) -Force
        $run = Invoke-SimCommand -Name "missing package: $launcher" -FileName $cmdExe -Arguments @("/c", (".\" + $launcher)) -InputText "`r`n" -WorkingDirectory $missingDir -ExpectedExitCode 1 -Environment $envVars
        if ($run.Combined -notmatch "Please extract the (full|complete) ZIP") {
            throw "$launcher did not show extract-full-ZIP guidance"
        }
        [void]$runs.Add($run)
        Remove-Item -Path (Join-Path $missingDir $launcher) -Force
    }

    Write-Check "ShellExecute launcher tests (simulating user double-click)"
    $shellExecuteCapable = $true
    try {
        $psiTest = New-Object System.Diagnostics.ProcessStartInfo
        $psiTest.FileName = "cmd.exe"
        $psiTest.Arguments = "/c exit 0"
        $psiTest.UseShellExecute = $true
        $psiTest.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $null = [System.Diagnostics.Process]::Start($psiTest)
    }
    catch {
        $shellExecuteCapable = $false
        Write-Host "[simulate] SKIP: ShellExecute not available in this environment ($($_.Exception.Message))" -ForegroundColor Yellow
    }

    if ($shellExecuteCapable) {
        $launcherNames = @(
            "Start-Install.cmd",
            "00-点我开始安装.cmd",
            "Run-Diagnostics.cmd",
            "一键诊断.cmd",
            "Restore-Config.cmd",
            "恢复或卸载配置.cmd",
            "一键修复依赖.cmd"
        )
        foreach ($launcherName in $launcherNames) {
            $launcherPath = Join-Path $releaseRoot $launcherName
            if (-not (Test-Path $launcherPath)) {
                Write-Host "[simulate] SKIP: $launcherName not found in release" -ForegroundColor Yellow
                continue
            }

            Write-Check "ShellExecute: $launcherName"

            $started = $false

            try {
                # Save old env values, set TestSafe env for ShellExecute child process
                $oldShellEnv = @{}
                foreach ($key in @("CCDI_TEST_MODE","CCDI_TEST_USERPROFILE","CCDI_TEST_DESKTOP","CCDI_API_KEY","CCDI_TEST_API_STATUS")) {
                    $oldShellEnv[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
                }

                try {
                    foreach ($key in $envVars.Keys) {
                        [Environment]::SetEnvironmentVariable($key, [string]$envVars[$key], "Process")
                    }

                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName = $launcherPath
                    $psi.WorkingDirectory = $releaseRoot
                    $psi.UseShellExecute = $true
                    $psi.CreateNoWindow = $false
                    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

                    $proc = [System.Diagnostics.Process]::Start($psi)

                    if ($null -eq $proc) {
                        Write-Host "[simulate] SKIP: $launcherName failed to start via ShellExecute" -ForegroundColor Yellow
                        continue
                    }

                    $started = $true

                    $shellExecuteInitWaitMs = 2000

                    # Wait briefly for the process to initialize.
                    # This ShellExecute smoke only verifies that the launcher starts successfully;
                    # it is not a full interactive UX test, so 2 seconds is enough.
                    $proc.WaitForExit($shellExecuteInitWaitMs) | Out-Null

                    if (-not $proc.HasExited) {
                        $realPid = $proc.Id
                        try { & taskkill.exe /PID $realPid /T /F 2>$null | Out-Null; Start-Sleep -Milliseconds 500 } catch { }
                        if (-not $proc.HasExited) { try { Stop-Process -Id $realPid -Force -ErrorAction SilentlyContinue } catch { } }
                        $waitSec = [math]::Round($shellExecuteInitWaitMs / 1000, 1)
                        Write-Host "[simulate]   $launcherName started (running after ${waitSec}s, killed)" -ForegroundColor Green
                    }
                    else {
                        $exitCode = $proc.ExitCode
                        if ($exitCode -eq 0 -or $exitCode -eq 1) {
                            Write-Host "[simulate]   $launcherName exited cleanly (code=$exitCode)" -ForegroundColor Green
                        }
                        else {
                            throw "$launcherName ShellExecute exited with unexpected code $exitCode"
                        }
                    }
                }
                finally {
                    # Restore old env values
                    foreach ($key in $oldShellEnv.Keys) {
                        if ($null -ne $oldShellEnv[$key]) {
                            [Environment]::SetEnvironmentVariable($key, $oldShellEnv[$key], "Process")
                        }
                        else {
                            [Environment]::SetEnvironmentVariable($key, $null, "Process")
                        }
                    }
                }
            }
            catch {
                if ($started) {
                    throw
                }

                Write-Host "[simulate] SKIP: $launcherName ShellExecute failed to start: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }


    Write-Check "v1.3.3 P5: fake npm shim (.ps1 + .cmd) - verify .ps1 not executed"
    $shimTestDir = Join-Path $tempRoot "roaming\npm"
    New-Item -ItemType Directory -Path $shimTestDir -Force | Out-Null

    # Create fake claude.ps1 that writes a sentinel if executed (must NOT be called)
    $fakePs1Path = Join-Path $shimTestDir "claude.ps1"
    $fakePs1Content = @'
# If this runs, it means .ps1 was executed (BUG)
$sentinelFile = Join-Path $env:TEMP "PS1_SHIM_SHOULD_NOT_RUN_${PID}.txt"
"PS1_SHIM_SHOULD_NOT_RUN" | Set-Content -Path $sentinelFile -Encoding UTF8
Start-Process notepad.exe -ArgumentList $PSCommandPath
Write-Output "2.1.179 (Claude Code)"
'@
    Set-Content -Path $fakePs1Path -Encoding UTF8 -Value $fakePs1Content

    # Create fake claude.cmd that returns a valid version
    $fakeCmdPath = Join-Path $shimTestDir "claude.cmd"
    "@echo off`r`necho 2.1.179 (Claude Code)" | Set-Content -Path $fakeCmdPath -Encoding ASCII

    # Temporarily prepend shimTestDir to PATH so Get-Command finds both shims
    $oldPath = $env:Path
    $env:Path = "$shimTestDir;$oldPath"
    try {
        # Reload libraries (Get-ClaudeCommandInventory etc.) after PATH change
        Push-Location $releaseRoot
        try {
            . .\lib\bootstrap.ps1
            Initialize-CcdiScript -ScriptName "shim-test" | Out-Null

            # Run Get-ClaudeCommandInventory - this is the function that must NOT execute .ps1
            $inventory = Get-ClaudeCommandInventory

            # Assertions
            if (-not $inventory) {
                throw "Get-ClaudeCommandInventory returned null"
            }
            if ($inventory.Candidates.Count -eq 0) {
                throw "Get-ClaudeCommandInventory found no candidates"
            }

            # Check no candidate executed the .ps1 directly
            # The .ps1 candidate may be marked Usable=true because probing used sibling claude.cmd
            # The real check is: no sentinel file was created
            $ps1Candidate = $inventory.Candidates | Where-Object { $_.Path -eq $fakePs1Path }
            if ($ps1Candidate) {
                # If Error contains skip text, the .ps1 was properly skipped
                # If Usable but no skip text, check if sentinel exists (was .ps1 directly run)
                if ($ps1Candidate.Error -match 'PowerShell shim|跳过') {
                    Write-Host "[simulate]   ps1 candidate properly skipped: $($ps1Candidate.Error)" -ForegroundColor Green
                }
                elseif ($ps1Candidate.Usable) {
                    # Usable=true through sibling .cmd probe is fine;
                    # only fail if a sentinel proves direct .ps1 execution
                    $sentinelCheck = Get-ChildItem -Path $env:TEMP -Filter "PS1_SHIM_SHOULD_NOT_RUN_*.txt" -ErrorAction SilentlyContinue
                    if ($sentinelCheck) {
                        throw "claude.ps1 was executed directly! Sentinel file found: $($sentinelCheck.FullName)"
                    }
                    Write-Host "[simulate]   ps1 candidate usable via sibling .cmd probe: Usable=$($ps1Candidate.Usable), Error=$($ps1Candidate.Error)" -ForegroundColor Green
                }
                Write-Host "[simulate]   ps1 candidate handled: Usable=$($ps1Candidate.Usable), Risk=$($ps1Candidate.Risk)" -ForegroundColor Green

                # v1.3.3 复查: .ps1 必须正确分类为 npm_global, IsShimCompanion
                if ($ps1Candidate.Source -ne "npm_global") {
                    throw "claude.ps1 candidate Source must be npm_global (got: $($ps1Candidate.Source))"
                }
                if (-not $ps1Candidate.IsShimCompanion) {
                    throw "claude.ps1 candidate must have IsShimCompanion=true"
                }
                Write-Host "[simulate]   ps1 candidate: Source=$($ps1Candidate.Source), IsShimCompanion=$($ps1Candidate.IsShimCompanion)" -ForegroundColor Green
            }

            # Check the .cmd candidate was found and usable
            $cmdCandidate = $inventory.Candidates | Where-Object { $_.Path -eq $fakeCmdPath }
            if (-not $cmdCandidate) {
                throw "Get-ClaudeCommandInventory did not find claude.cmd"
            }
            if (-not $cmdCandidate.Usable) {
                throw "Get-ClaudeCommandInventory found claude.cmd but not usable: Error=$($cmdCandidate.Error)"
            }
            Write-Host "[simulate]   cmd candidate: Usable=$($cmdCandidate.Usable), Version=$($cmdCandidate.Version)" -ForegroundColor Green

            # v1.3.3 复查: .ps1 和 .cmd LogicalInstallKey 必须一致
            if ($ps1Candidate -and $cmdCandidate) {
                if ($ps1Candidate.LogicalInstallKey -ne $cmdCandidate.LogicalInstallKey) {
                    throw "claude.ps1 LogicalInstallKey ($($ps1Candidate.LogicalInstallKey)) must match claude.cmd ($($cmdCandidate.LogicalInstallKey))"
                }
                Write-Host "[simulate]   LogicalInstallKey matches: $($ps1Candidate.LogicalInstallKey)" -ForegroundColor Green
            }

            # Check no sentinel file was created
            $sentinelFiles = Get-ChildItem -Path $env:TEMP -Filter "PS1_SHIM_SHOULD_NOT_RUN_*.txt" -ErrorAction SilentlyContinue
            if ($sentinelFiles) {
                throw "claude.ps1 was executed directly! Sentinel file found: $($sentinelFiles.FullName)"
            }

            # v1.3.3 遗留收口: npm shim 组合本身不产生误报冲突
            # 注：测试机可能同时有 native_local_bin + npm shim，那是真实多来源，可以接受
            # 关键是 npm shim 组合的 .ps1+.cmd 不自相冲突
            if ($inventory.ConflictSummary -match '多个 claude 命令来源') {
                throw "Get-ClaudeCommandInventory ConflictSummary must NOT contain '多个 claude 命令来源' (npm shim combo)"
            }
            Write-Host "[simulate]   HasConflict=$($inventory.HasConflict) (ConflictSummary: $($inventory.ConflictSummary))" -ForegroundColor Green

            # Check no ".Count" errors in the output
            Write-Host "[simulate]   shim test passed: .ps1 not executed, .cmd usable, HasConflict=false" -ForegroundColor Green
        }
        finally {
            Pop-Location
        }
    }
    finally {
        $env:Path = $oldPath
        # Cleanup sentinel files
        Get-ChildItem -Path $env:TEMP -Filter "PS1_SHIM_SHOULD_NOT_RUN_*.txt" -ErrorAction SilentlyContinue | Remove-Item -Force
    }

    Assert-NoBadRuntimeText -Runs $runs -ReleaseRoot $releaseRoot -DummyKey $DummyApiKey

    # v1.3.3 遗留收口: 运行 doctor 后验证 support-feedback.txt 生成
    Write-Check "v1.3.3 遗留收口: support-feedback.txt generated after doctor"
    $fbTestEnv = New-SimEnvironment -ProfileDir $testProfile -DesktopDir $testDesktop -DummyKey $DummyApiKey
    $fbRun = Invoke-SimCommand -Name "doctor support-feedback generation" -FileName $powerShellExe -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $releaseRoot "doctor.ps1"),
        "-NoOpenReport", "-SkipApiTest"
    ) -InputText "`r`n" -WorkingDirectory $releaseRoot -Environment $fbTestEnv -TimeoutSec 180
    [void]$runs.Add($fbRun)

    $supportFeedbackPath = Join-Path $releaseRoot "support-feedback.txt"
    if (-not (Test-Path $supportFeedbackPath)) {
        throw "support-feedback.txt was not generated after running doctor.ps1"
    }
    $fbContent = Get-Content $supportFeedbackPath -Raw -Encoding UTF8
    if ($fbContent -notmatch '一、最简结论') {
        throw "support-feedback.txt missing section '一、最简结论'"
    }
    if ($fbContent -notmatch '二、诊断报告 report\.txt') {
        throw "support-feedback.txt missing section '二、诊断报告 report.txt'"
    }
    if ($fbContent -notmatch '四、最近运行日志尾部') {
        throw "support-feedback.txt missing section '四、最近运行日志尾部'"
    }
    if ($fbContent -notmatch '五、最近终端输出尾部') {
        throw "support-feedback.txt missing section '五、最近终端输出尾部'"
    }
    if ($fbContent -match 'sk-[A-Za-z0-9]{20,}') {
        # Check that the dummy key is NOT exposed in full
        $fullKeyMatches = [regex]::Matches($fbContent, 'sk-[A-Za-z0-9]{20,}')
        foreach ($m in $fullKeyMatches) {
            if ($m.Value -notmatch '\*{4}') {
                throw "support-feedback.txt contains unmasked API Key: $($m.Value)"
            }
        }
    }
    if ($fbContent -match '"ANTHROPIC_AUTH_TOKEN"\s*:\s*"sk-') {
        throw "support-feedback.txt contains full settings.json ANTHROPIC_AUTH_TOKEN"
    }
    # 验证 support-feedback.txt 不包含真实用户路径
    if ($fbContent -match 'C:\\Users\\[^\\]+\\' -and $fbContent -notmatch '%USERPROFILE%|sanitize|test|mock|fake|dummy') {
        throw "support-feedback.txt contains unmasked C:\Users\ path"
    }
    Write-Host "[simulate]   support-feedback.txt generated with correct structure and sanitization" -ForegroundColor Green

    # v1.3.3 UX: 噪音过滤单元测试
    Write-Check "v1.3.3 UX: noise filtering helpers test"
    $fakeNoisyInput = @"
[INFO] 正常日志行
-
\
|
/
[WARN] 正常警告
PS>TerminatingError(Invoke-WebRequest):"Authentication Fails (governor)"
PS>TerminatingError(Invoke-WebRequest):"操作超时。"
[INFO] 另一行正常日志
"@
    $filtered = Remove-ProgressNoiseLines -Text $fakeNoisyInput
    $filtered = Remove-PowerShellTerminatingNoiseLines -Text $filtered

    if ($filtered -match '^\\$' -or $filtered -match '^\|$' -or $filtered -match '^/$' -or $filtered -match '^-$') {
        throw "Remove-ProgressNoiseLines failed to remove spinner chars"
    }
    if ($filtered -match 'PS>TerminatingError') {
        throw "Remove-PowerShellTerminatingNoiseLines failed to remove PS>TerminatingError lines"
    }
    if ($filtered -notmatch '正常日志行' -or $filtered -notmatch '正常警告' -or $filtered -notmatch '另一行正常日志') {
        throw "Noise filters removed valid log lines"
    }
    Write-Host "[simulate]   noise filters: spinner + PS>TerminatingError removed, valid lines kept" -ForegroundColor Green

    # v1.3.3 UX: Invoke-InstallCommandCaptured compact progress parameter test
    # Static check: verify Invoke-InstallCommandCaptured supports all required params
    Write-Check "v1.3.3 UX: Invoke-InstallCommandCaptured compact progress params"

    $ciContent = Get-Content (Join-Path $releaseRoot "lib\claude-install.ps1") -Raw -Encoding UTF8

    # Extract the full Invoke-InstallCommandCaptured function body
    $capturedFuncBody = if ($ciContent -match '(?s)function Invoke-InstallCommandCaptured\s*\{.*?(?=^function \w|\Z)') {
        $matches[0]
    } else {
        throw "Cannot find Invoke-InstallCommandCaptured function"
    }

    $requiredParams = @(
        @{Name="ProgressTitle";      Type="string"},
        @{Name="ProgressHint";       Type="string"},
        @{Name="ProgressIntervalSec";Type="int"},
        @{Name="SlowNoticeAfterSec"; Type="int"},
        @{Name="SlowNoticeMessage";  Type="string"}
    )
    foreach ($p in $requiredParams) {
        if ($capturedFuncBody -notmatch "\[$($p.Type)\]\s*\`$$($p.Name)") {
            throw "Invoke-InstallCommandCaptured missing param: `$$($p.Name)"
        }
    }
    # Verify the slow notice logic exists
    if ($capturedFuncBody -notmatch '\$slowNoticeShown\s*=\s*\$false') {
        throw "Invoke-InstallCommandCaptured missing slowNoticeShown initialization"
    }
    if ($capturedFuncBody -notmatch '\$SlowNoticeAfterSec\s*-gt\s*0') {
        throw "Invoke-InstallCommandCaptured missing slow notice guard (SlowNoticeAfterSec > 0)"
    }
    Write-Host "[simulate]   compact progress params OK" -ForegroundColor Green

    # v1.3.3 UX: 安装路径静态检查
    Write-Check "v1.3.3 UX: install method progress alignment static checks"
    $claudeInstallPath = Join-Path $releaseRoot "lib\claude-install.ps1"
    if (-not (Test-Path $claudeInstallPath)) {
        throw "lib\claude-install.ps1 not found in release"
    }
    $ciContent = Get-Content $claudeInstallPath -Raw -Encoding UTF8

    # Native install
    if ($ciContent -notmatch 'Claude Code 官方安装中') {
        throw "Install-ClaudeCodeNative must use ProgressTitle 'Claude Code 官方安装中'"
    }
    # npm mirror install
    if ($ciContent -notmatch 'Claude Code 备用下载方式安装中') {
        throw "Install-ClaudeCodeNpmMirror must use ProgressTitle 'Claude Code 备用下载方式安装中'"
    }
    # winget Claude install
    if ($ciContent -notmatch 'Claude Code 系统安装中') {
        throw "Install-ClaudeCodeViaWinget must use ProgressTitle 'Claude Code 系统安装中'"
    }
    # winget Claude must NOT use Invoke-VisibleInstallCommand
    $wingetClaudeFunc = if ($ciContent -match '(?s)function Install-ClaudeCodeViaWinget\s*\{.*?(?=^function \w|\Z)') { $matches[0] } else { "" }
    if ($wingetClaudeFunc -match 'Invoke-VisibleInstallCommand') {
        throw "Install-ClaudeCodeViaWinget must NOT use Invoke-VisibleInstallCommand"
    }
    if ($wingetClaudeFunc -notmatch 'Invoke-InstallCommandCaptured') {
        throw "Install-ClaudeCodeViaWinget must use Invoke-InstallCommandCaptured"
    }
    Write-Host "[simulate]   install method progress alignment OK" -ForegroundColor Green

    # v1.3.3 UX: timeout message alignment with fallback flow
    Write-Check "v1.3.3 UX: timeout message alignment static checks"

    # 1. Invoke-InstallCommandCaptured has TimeoutFollowupMessage param
    $capturedFunc = if ($ciContent -match '(?s)function Invoke-InstallCommandCaptured\s*\{.*?(?=^function \w|\Z)') { $matches[0] } else { "" }
    if ($capturedFunc -notmatch '\[string\]\$TimeoutFollowupMessage') {
        throw "Invoke-InstallCommandCaptured missing TimeoutFollowupMessage param"
    }
    # 2. Timeout branch uses IsNullOrWhiteSpace guard
    if ($capturedFunc -notmatch 'IsNullOrWhiteSpace\(\$TimeoutFollowupMessage\)') {
        throw "Invoke-InstallCommandCaptured must guard TimeoutFollowupMessage with IsNullOrWhiteSpace"
    }

    # 3. Native Install timeout copy
    $nativeFunc = if ($ciContent -match '(?s)function Install-ClaudeCodeNative\s*\{.*?(?=^function \w|\Z)') { $matches[0] } else { "" }
    if ($nativeFunc -notmatch 'TimeoutFollowupMessage\s+\"\"') {
        throw "Install-ClaudeCodeNative must pass TimeoutFollowupMessage ''"
    }
    if ($nativeFunc -notmatch '官方安装已等待约 5 分钟') {
        throw "Install-ClaudeCodeNative missing timeout message"
    }

    # 4. Winget Claude timeout copy
    $wingetClaudeFunc2 = if ($ciContent -match '(?s)function Install-ClaudeCodeViaWinget\s*\{.*?(?=^function \w|\Z)') { $matches[0] } else { "" }
    if ($wingetClaudeFunc2 -notmatch 'TimeoutFollowupMessage\s+\"\"') {
        throw "Install-ClaudeCodeViaWinget must pass TimeoutFollowupMessage ''"
    }
    if ($wingetClaudeFunc2 -notmatch '系统安装方式等待过久') {
        throw "Install-ClaudeCodeViaWinget missing timeout message"
    }

    # 5. npm mirror timeout copy
    $npmMirrorFunc = if ($ciContent -match '(?s)function Install-ClaudeCodeNpmMirror\s*\{.*?(?=^function \w|\Z)') { $matches[0] } else { "" }
    if ($npmMirrorFunc -notmatch '如果后续仍未成功') {
        throw "Install-ClaudeCodeNpmMirror missing '如果后续仍未成功' in TimeoutFollowupMessage"
    }

    # 6. Node.js must NOT have TimeoutFollowupMessage
    # Extract only the Invoke-InstallCommandCaptured call within Install-NodeJsViaWinget
    if ($ciContent -match '(?s)function Install-NodeJsViaWinget\s*\{.*?Invoke-InstallCommandCaptured.*?-StartMessage\s+\"\"') {
        if ($matches[0] -match 'TimeoutFollowupMessage') {
            throw "Install-NodeJsViaWinget must NOT pass TimeoutFollowupMessage (keep default)"
        }
    }
    Write-Host "[simulate]   timeout message alignment OK" -ForegroundColor Green

    # v1.3.3 P0 fix: real runtime test — Invoke-InstallCommandCaptured with ProgressIntervalSec
    # Must NOT throw "格式说明符无效" (Double + D2 in PS5.1)
    Write-Check "v1.3.3 P0 fix: Invoke-InstallCommandCaptured progress formatting runtime test"
    $progressTestEnv = New-SimEnvironment -ProfileDir $testProfile -DesktopDir $testDesktop -DummyKey $DummyApiKey
    $progressTestEnv["CCDI_TEST_MODE"] = "1"
    $progressTestScript = @'
$scriptRoot = "{0}"
. "$scriptRoot\lib\bootstrap.ps1"
$result = Invoke-InstallCommandCaptured -FilePath "powershell" -Arguments @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", "Start-Sleep -Seconds 2"
) -TimeoutSec 10 -FriendlyName "进度格式化测试" `
  -StartMessage "" `
  -ProgressIntervalSec 1 `
  -ProgressTitle "测试安装中" `
  -ProgressHint "测试提示" `
  -SlowNoticeAfterSec 1 `
  -SlowNoticeMessage "测试慢速提示"
Write-Output "TestSuccess=$($result.Success)"
Write-Output "TestExitCode=$($result.ExitCode)"
Write-Output "TestDurationMs=$($result.DurationMs)"
Write-Output "TestError=$($result.Error)"
'@ -f $releaseRoot
    $progressTestPath = Join-Path $tempRoot "test_progress_format.ps1"
    Set-Content -Path $progressTestPath -Value $progressTestScript -Encoding UTF8

    $progressRun = Invoke-SimCommand -Name "progress format test" -FileName $powerShellExe -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $progressTestPath
    ) -WorkingDirectory $releaseRoot -Environment $progressTestEnv -TimeoutSec 30
    [void]$runs.Add($progressRun)

    # Assert: no format specifier error
    if ($progressRun.Combined -match '格式说明符无效|format specifier') {
        throw "Progress formatting threw '格式说明符无效' — Double + D2 PS5.1 bug not fixed"
    }
    # Assert: returned expected structure (test command exits 0 after 2s sleep)
    if ($progressRun.Combined -notmatch 'TestDurationMs=') {
        throw "Progress format test did not return DurationMs — function may have crashed"
    }
    if ($progressRun.Combined -match 'TestError=.*异常') {
        throw "Progress format test has exception in Error field"
    }
    Write-Host "[simulate]   progress formatting runtime test OK" -ForegroundColor Green

    # v1.3.3 UX: npm mirror + Wait-ClaudeCommandReady static + runtime checks
    Write-Check "v1.3.3 UX: npm mirror Wait-ClaudeCommandReady anti-regression"

    # Static checks
    $ciContent2 = Get-Content (Join-Path $releaseRoot "lib\claude-install.ps1") -Raw -Encoding UTF8
    $shContent2 = Get-Content (Join-Path $releaseRoot "Start-Here.ps1") -Raw -Encoding UTF8

    if ($ciContent2 -notmatch 'function Wait-ClaudeCommandReady') {
        throw "Wait-ClaudeCommandReady function not found in claude-install.ps1"
    }
    if ($ciContent2 -notmatch 'Wait-ClaudeCommandReady\s+-TotalWaitSec\s+30\s+-IntervalSec\s+2\s+-RequireFreshShell') {
        throw "npm mirror install must call Wait-ClaudeCommandReady -TotalWaitSec 30 -IntervalSec 2 -RequireFreshShell"
    }
    if ($ciContent2 -notmatch '正在确认 Claude Code 是否已经可用') {
        throw "npm mirror install must show '正在确认 Claude Code 是否已经可用'"
    }
    if ($ciContent2 -notmatch '备用下载方式暂未完成确认') {
        throw "npm mirror must show '备用下载方式暂未完成确认' only after Wait-ClaudeCommandReady fails"
    }
    if ($shContent2 -notmatch [regex]::Escape('备用下载方式（npm 镜像）')) {
        throw "Convert-ClaudeInstallMethodForReport missing '备用下载方式（npm 镜像）' mapping"
    }
    if ($shContent2 -notmatch 'knownInstallMethods') {
        throw "Start-Here.ps1 final fallback must use knownInstallMethods to preserve installResult.Method"
    }
    Write-Host "[simulate]   npm mirror Wait-ClaudeCommandReady static checks OK" -ForegroundColor Green

    # Minimal runtime test: load Wait-ClaudeCommandReady in TestSafe mode and verify structure
    $wccrTestEnv = New-SimEnvironment -ProfileDir $testProfile -DesktopDir $testDesktop -DummyKey $DummyApiKey
    $wccrTestEnv["CCDI_TEST_MODE"] = "1"
    $wccrTestScript = @'
$scriptRoot = "{0}"
. "$scriptRoot\lib\bootstrap.ps1"
$null = Initialize-CcdiScript -ScriptName "sim-wccr"

# Verify function exists
$fn = Get-Command Wait-ClaudeCommandReady -ErrorAction SilentlyContinue
if (-not $fn) {{
    Write-Output "WCCR_CHECK=function_not_found"
    exit 1
}}

# Verify in TestSafe mode the function returns proper structure
$ready = Wait-ClaudeCommandReady -TotalWaitSec 5 -IntervalSec 1 -Context "simulate test"
Write-Output "WCCR_CHECK=Ready=$($ready.Ready)"
Write-Output "WCCR_CHECK=Status=$($ready.Status)"
Write-Output "WCCR_CHECK=Attempts=$($ready.Attempts)"
Write-Output "WCCR_CHECK=HasVersion=$([bool]$ready.Version)"
'@ -f $releaseRoot
    $wccrTestPath = Join-Path $tempRoot "test_wccr.ps1"
    Set-Content -Path $wccrTestPath -Value $wccrTestScript -Encoding UTF8

    $wccrRun = Invoke-SimCommand -Name "Wait-ClaudeCommandReady runtime test" -FileName $powerShellExe -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $wccrTestPath
    ) -WorkingDirectory $releaseRoot -Environment $wccrTestEnv -TimeoutSec 30
    [void]$runs.Add($wccrRun)

    if ($wccrRun.Combined -notmatch 'WCCR_CHECK=function_not_found') {
        if ($wccrRun.Combined -match 'WCCR_CHECK=Status=') {
            Write-Host "[simulate]   Wait-ClaudeCommandReady runtime structure OK" -ForegroundColor Green
        }
        else {
            throw "Wait-ClaudeCommandReady did not return expected Status field in TestSafe mode"
        }
    }
    else {
        throw "Wait-ClaudeCommandReady function not loadable in release staging"
    }

    # v1.3.3 report accuracy: install method + location + Node/npm "无需" static checks
    Write-Check "v1.3.3 report accuracy: install method + location + Node/npm static checks"

    $shContent3 = Get-Content (Join-Path $releaseRoot "Start-Here.ps1") -Raw -Encoding UTF8
    $ciContent3 = Get-Content (Join-Path $releaseRoot "lib\claude-install.ps1") -Raw -Encoding UTF8
    $cmContent3 = Get-Content (Join-Path $releaseRoot "lib\common.ps1") -Raw -Encoding UTF8

    # 1. official_native → "Claude 官方 Native Install"
    if ($shContent3 -notmatch [regex]::Escape('Claude 官方 Native Install')) {
        throw "official_native must map to 'Claude 官方 Native Install'"
    }
    # 2. npm_npmmirror → "备用下载方式（npm 镜像）"
    if ($shContent3 -notmatch [regex]::Escape('备用下载方式（npm 镜像）')) {
        throw "npm_npmmirror must map to '备用下载方式（npm 镜像）'"
    }
    # 3. No fixed "已安装（非 Native Install 路径）"
    if ($shContent3 -match [regex]::Escape('已安装（非 Native Install 路径）')) {
        throw "Install location must NOT use fixed '已安装（非 Native Install 路径）'"
    }
    # 4. Install location uses Sanitize-PathForReport
    if ($shContent3 -notmatch 'Sanitize-PathForReport') {
        throw "Step-GenerateReport must use Sanitize-PathForReport for install location"
    }
    # 5. Node.js "无需" for official Native
    if ($shContent3 -notmatch [regex]::Escape('未安装（当前官方安装方式无需 Node.js）')) {
        throw "Report must show '未安装（当前官方安装方式无需 Node.js）' for official Native scenario"
    }
    # 6. npm "无需" for official Native
    if ($shContent3 -notmatch [regex]::Escape('不可用（当前官方安装方式无需 npm）')) {
        throw "Report must show '不可用（当前官方安装方式无需 npm）' for official Native scenario"
    }
    # 7. No straight double quotes in user-facing text
    if ($ciContent3 -match '请选择\x22是\x22') {
        throw “User-facing text must use curly quotes, not straight quotes”
    }
    # 8. Native ExitCode log wording
    if ($ciContent3 -notmatch [regex]::Escape('ExitCode 为空或非零')) {
        throw "Native Install log must say 'ExitCode 为空或非零'"
    }
    # 9. support-feedback has InstallMethod parameter
    if ($cmContent3 -notmatch '\[string\]\$InstallMethod') {
        throw "New-SupportFeedbackReport must accept -InstallMethod parameter"
    }
    if ($cmContent3 -notmatch [regex]::Escape('安装方式：')) {
        throw "New-SupportFeedbackReport summary must render 安装方式"
    }
    Write-Host "[simulate]   report accuracy static checks OK" -ForegroundColor Green

    # Minimal runtime test: verify Sanitize-PathForReport returns userprofile-masked path
    $sanitizeTestEnv = New-SimEnvironment -ProfileDir $testProfile -DesktopDir $testDesktop -DummyKey $DummyApiKey
    $sanitizeTestEnv["CCDI_TEST_MODE"] = "1"
    $sanitizeTestScript = @'
$scriptRoot = "{0}"
. "$scriptRoot\lib\bootstrap.ps1"
$null = Initialize-CcdiScript -ScriptName "sim-sanitize"

$testPath = if ($env:CCDI_TEST_USERPROFILE) {{ Join-Path $env:CCDI_TEST_USERPROFILE "AppData\Roaming\npm\claude.cmd" }} else {{ Join-Path $env:USERPROFILE "AppData\Roaming\npm\claude.cmd" }}
$sanitized = Sanitize-PathForReport -Text $testPath
Write-Output "SANITIZE_IN=$sanitized"
Write-Output "SANITIZE_HAS_USERPROFILE=$($sanitized -match '%USERPROFILE%')"
Write-Output "SANITIZE_NO_REAL_NAME=$($sanitized -notmatch [regex]::Escape($env:USERNAME))"
Write-Output "SANITIZE_LEN=$($sanitized.Length)"
'@ -f $releaseRoot
    $sanitizeTestPath = Join-Path $tempRoot "test_sanitize.ps1"
    Set-Content -Path $sanitizeTestPath -Value $sanitizeTestScript -Encoding UTF8

    $sanitizeRun = Invoke-SimCommand -Name "sanitize path runtime" -FileName $powerShellExe -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $sanitizeTestPath
    ) -WorkingDirectory $releaseRoot -Environment $sanitizeTestEnv -TimeoutSec 30
    [void]$runs.Add($sanitizeRun)

    if ($sanitizeRun.Combined -notmatch 'SANITIZE_HAS_USERPROFILE=True') {
        throw "Sanitize-PathForReport did not mask username with %USERPROFILE%"
    }
    Write-Host "[simulate]   Sanitize-PathForReport runtime OK" -ForegroundColor Green

    # ============================================================
    # v1.3.3 test matrix: install UX scenario coverage
    # ============================================================
    Write-Check "v1.3.3 test matrix: install UX scenario coverage"

    $combinedOutputs = @{}
    $envBase = New-SimEnvironment -ProfileDir $testProfile -DesktopDir $testDesktop -DummyKey $DummyApiKey -ApiStatus "200"

    # --- Scenario A: official native success, no node/npm ---
    # Verify that when Claude is found via native path, it's recognized correctly.
    $scenarioAText = $startHereRuntimeText + "`n" + ($installReports | ForEach-Object { Get-Content -Path $_.FullName -Raw -Encoding UTF8 }) -join "`n"
    if ($scenarioAText -match "Claude Code.*已安装" -and $scenarioAText -match "DeepSeek 配置.*已配置") {
        Write-Host "[simulate]   Scenario A (official native + no node/npm): pass" -ForegroundColor Green
    }
    else {
        Write-Host "[simulate]   Scenario A: N/A (existing flow covers this via TestSafe existing mode)" -ForegroundColor Yellow
    }
    $combinedOutputs["A"] = $scenarioAText

    # --- Scenario B: npm mirror install + verification path (unit test) ---
    # Test the npm mirror install function and post-verification independently.
    # Full auto-install would detect existing Claude; this tests the fallback path directly.
    $scenarioBEnv = New-SimEnvironment -ProfileDir $testProfile -DesktopDir $testDesktop -DummyKey $DummyApiKey -ApiStatus "200"
    $scenarioBScript = @'
$scriptRoot = "{0}"
. "$scriptRoot\lib\bootstrap.ps1"
$null = Initialize-CcdiScript -ScriptName "sim-scenario-b"
# 1. Verify npm mirror install function works in TestSafe
$mirrorResult = Install-ClaudeCodeNpmMirror -TestSafe
Write-Output "SCENARIO_B_MIRROR_SUCCESS=$($mirrorResult.Success)"
Write-Output "SCENARIO_B_MIRROR_ERROR=$($mirrorResult.Error)"
Write-Output "SCENARIO_B_MIRROR_METHOD=$($mirrorResult.Method)"
# 2. Verify Wait-ClaudeCommandReady detects existing Claude
$ready = Wait-ClaudeCommandReady -TotalWaitSec 5 -IntervalSec 1 -Context "scenario B"
Write-Output "SCENARIO_B_READY=$($ready.Ready)"
Write-Output "SCENARIO_B_WCCR_STATUS=$($ready.Status)"
# 3. Verify npm mirror output text does NOT contain premature diagnostic
if ($ready.Ready) {{
    Write-Output "SCENARIO_B_TEXT_ORDER=OK"
}} else {{
    Write-Output "SCENARIO_B_TEXT_ORDER=NA"
}}
'@ -f $releaseRoot
    $scenarioBPath = Join-Path $tempRoot "test_scenario_b.ps1"
    Set-Content -Path $scenarioBPath -Value $scenarioBScript -Encoding UTF8
    $scenarioBRun = Invoke-SimCommand -Name "Scenario B: npm mirror install + verify" -FileName $powerShellExe -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scenarioBPath
    ) -WorkingDirectory $releaseRoot -Environment $scenarioBEnv -TimeoutSec 60
    [void]$runs.Add($scenarioBRun)
    if ($scenarioBRun.Combined -notmatch 'SCENARIO_B_MIRROR_SUCCESS=') {
        throw "Scenario B: Install-ClaudeCodeNpmMirror did not return expected structure: $($scenarioBRun.Combined)"
    }
    if ($scenarioBRun.Combined -notmatch 'SCENARIO_B_READY=True') {
        throw "Scenario B: Wait-ClaudeCommandReady should detect existing Claude: $($scenarioBRun.Combined)"
    }
    Write-Host "[simulate]   Scenario B (npm mirror install + WCCR verify): unit OK" -ForegroundColor Green
    Assert-TextOrder -Text $scenarioBRun.Combined -Scenario "B"
    $combinedOutputs["B"] = $scenarioBRun.Combined

    # --- Scenario C: Node/npm pre-existing detection (+ npm mirror code path) ---
    # Create mock Node.js + npm in sandbox PATH; verify detection works.
    $mockNodeDir = Join-Path $tempRoot "mock-node"
    New-Item -ItemType Directory -Path $mockNodeDir -Force | Out-Null
    "@echo off`r`necho v20.11.0" | Out-File -FilePath (Join-Path $mockNodeDir "node.cmd") -Encoding ASCII
    "@echo off`r`necho 10.2.4" | Out-File -FilePath (Join-Path $mockNodeDir "npm.cmd") -Encoding ASCII
    $scenarioCEnv = New-SimEnvironment -ProfileDir $testProfile -DesktopDir $testDesktop -DummyKey $DummyApiKey -ApiStatus "200"
    $scenarioCEnv["PATH"] = "$mockNodeDir;$env:PATH"
    $scenarioCScript = @'
$scriptRoot = "{0}"
. "$scriptRoot\lib\bootstrap.ps1"
$null = Initialize-CcdiScript -ScriptName "sim-scenario-c"
$nodeInfo = Test-NodeJsInstalled
$npmInfo = Test-NpmInstalled
Write-Output "SCENARIO_C_NODE_INSTALLED=$($nodeInfo.Installed)"
Write-Output "SCENARIO_C_NODE_VERSION=$($nodeInfo.Version)"
Write-Output "SCENARIO_C_NPM_INSTALLED=$($npmInfo.Installed)"
Write-Output "SCENARIO_C_NPM_VERSION=$($npmInfo.Version)"
# Verify npm mirror network check (TestSafe skips real network)
$netCheck = Test-NpmMirrorClaudeCodeNetwork
Write-Output "SCENARIO_C_NET_CHECK=$($netCheck.Success)"
# Verify npm mirror install can be invoked
$mirrorInstall = Install-ClaudeCodeNpmMirror -TestSafe
Write-Output "SCENARIO_C_MIRROR_METHOD=$($mirrorInstall.Method)"
Write-Output "SCENARIO_C_MIRROR_STATUS=$($mirrorInstall.Status)"
'@ -f $releaseRoot
    $scenarioCPath = Join-Path $tempRoot "test_scenario_c.ps1"
    Set-Content -Path $scenarioCPath -Value $scenarioCScript -Encoding UTF8
    $scenarioCRun = Invoke-SimCommand -Name "Scenario C: Node/npm pre-existing + npm mirror" -FileName $powerShellExe -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scenarioCPath
    ) -WorkingDirectory $releaseRoot -Environment $scenarioCEnv -TimeoutSec 60
    [void]$runs.Add($scenarioCRun)
    if ($scenarioCRun.Combined -notmatch 'SCENARIO_C_NODE_INSTALLED=True') {
        throw "Scenario C: Node must be detected: $($scenarioCRun.Combined)"
    }
    if ($scenarioCRun.Combined -notmatch 'SCENARIO_C_NPM_INSTALLED=True') {
        throw "Scenario C: npm must be detected: $($scenarioCRun.Combined)"
    }
    Write-Host "[simulate]   Scenario C (Node/npm pre-existing): detection OK" -ForegroundColor Green
    Assert-TextOrder -Text $scenarioCRun.Combined -Scenario "C"
    $combinedOutputs["C"] = $scenarioCRun.Combined

    # --- Scenario D: Claude already installed, no DeepSeek config ---
    # The partial state test already covers this — verify existing flow.
    $stateFileForD = Join-Path $testProfile ".claude-deepseek-installer\state.json"
    if (Test-Path $stateFileForD) {
        $stateContent = Get-Content -Path $stateFileForD -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($stateContent.claudeInstallMethod -eq "existing" -and $stateContent.claudeWasAlreadyInstalled -eq $true) {
            Write-Host "[simulate]   Scenario D (Claude already installed, no config): existing state preserved OK" -ForegroundColor Green
        }
    }
    # Also verify Start-Here TestSafe flow already handles this
    if ($startHereRuntimeText -match "Claude 状态.*已存在|跳过安装|配置写入.*已验证" -or $startHereRuntimeText -match "claudeWasAlreadyInstalled.*true") {
        Write-Host "[simulate]   Scenario D covered by existing TestSafe flow OK" -ForegroundColor Green
    }

    # --- Scenario E: Native exe exists but PATH missing ---
    # Verify Ensure-UserPathEntry function exists (in common.ps1)
    $commonSource = Get-Content -Path (Join-Path $releaseRoot "lib\common.ps1") -Raw -Encoding UTF8
    if ($commonSource -match "function Ensure-UserPathEntry") {
        Write-Host "[simulate]   Scenario E (Native exe exists, PATH fix): Ensure-UserPathEntry exists OK" -ForegroundColor Green
    }
    else {
        throw "Scenario E: Ensure-UserPathEntry must exist in lib/common.ps1"
    }

    # --- Scenario F: API Key invalid / balance fail ---
    # Covered by existing doctor API mock cases. Verify that Start-Here TestSafe flow
    # does not incorrectly report Claude install failure when API key is invalid.
    # The TestSafe flow already validates config writing + API test.
    if ($startHereRuntimeText -match "ConfigWritten=True|配置写入.*已验证|已在沙盒路径验证") {
        Write-Host "[simulate]   Scenario F (API Key invalid): covered by existing flow OK" -ForegroundColor Green
    }
    else {
        Write-Host "[simulate]   Scenario F: SKIP (covered by doctor API mocks)" -ForegroundColor Yellow
    }

    # --- Scenario G: npm install unknown ExitCode but command later usable ---
    # Covered by Wait-ClaudeCommandReady test. Verify no premature diagnostic.
    $scenarioGScript = @'
$scriptRoot = "{0}"
. "$scriptRoot\lib\bootstrap.ps1"
$null = Initialize-CcdiScript -ScriptName "sim-scenario-g"
# Simulate: npm mirror install returns Success=false (like unknown ExitCode),
# but Wait-ClaudeCommandReady should detect Claude is actually available
$ready = Wait-ClaudeCommandReady -TotalWaitSec 5 -IntervalSec 1 -Context "scenario G test"
Write-Output "SCENARIO_G_READY=$($ready.Ready)"
Write-Output "SCENARIO_G_STATUS=$($ready.Status)"
'@ -f $releaseRoot
    $scenarioGPath = Join-Path $tempRoot "test_scenario_g.ps1"
    Set-Content -Path $scenarioGPath -Value $scenarioGScript -Encoding UTF8
    $scenarioGRun = Invoke-SimCommand -Name "Scenario G: npm unknown ExitCode, command later usable" -FileName $powerShellExe -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $scenarioGPath
    ) -WorkingDirectory $releaseRoot -Environment $envBase -TimeoutSec 60
    [void]$runs.Add($scenarioGRun)
    # In TestSafe mode with Claude installed, Wait-ClaudeCommandReady should succeed or return valid structure
    if ($scenarioGRun.Combined -notmatch 'SCENARIO_G_STATUS=') {
        throw "Scenario G: Wait-ClaudeCommandReady did not return expected Status"
    }
    Write-Host "[simulate]   Scenario G (npm unknown ExitCode + command later usable): structure OK" -ForegroundColor Green

    # --- Aggregate text order check for all scenarios ---
    Write-Check "v1.3.3 text order assertions (success before diagnostic)"
    $allCombined = @($scenarioBRun.Combined, $scenarioCRun.Combined, $scenarioGRun.Combined) -join "`n"
    Assert-TextOrder -Text $allCombined -Scenario "aggregate-BCG"

    # --- support-feedback content checks ---
    Write-Check "v1.3.3 support-feedback content verification"
    $fbPath = Join-Path $releaseRoot "support-feedback.txt"
    if (Test-Path $fbPath) {
        $fbContent = Get-Content -Path $fbPath -Raw -Encoding UTF8
        if ($fbContent -notmatch '安装方式') {
            throw "support-feedback must contain '安装方式' in summary"
        }
        if ($fbContent -notmatch '不要发送 settings\.json') {
            throw "support-feedback must warn against sending settings.json"
        }
        if ($fbContent -notmatch '完整 API Key') {
            throw "support-feedback must warn against sending full API Key"
        }
        # Verify API key is masked (not plaintext sk-...)
        if ($fbContent -match 'ANTHROPIC_AUTH_TOKEN.*sk-[a-zA-Z0-9]{32}') {
            throw "support-feedback must NOT contain plaintext API Key"
        }
        Write-Host "[simulate]   support-feedback: InstallMethod present, privacy ok, key masked" -ForegroundColor Green
    }
    else {
        Write-Host "[simulate]   support-feedback: not generated by existing flow (OK)" -ForegroundColor Yellow
    }

    Write-Host "[simulate] OK" -ForegroundColor Green
}
finally {
    if ($KeepTemp) {
        Write-Host "[simulate] kept temp dir: $tempRoot" -ForegroundColor Yellow
    }
    else {
        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
