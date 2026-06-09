# ============================================================
# scripts/simulate-user-release.ps1 - Release 用户路径模拟验收
# ============================================================

param(
    [string]$Version = "1.3.0",
    [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BuildScript = Join-Path $ProjectRoot "scripts\build-release.ps1"
$ReleaseDir = Join-Path $ProjectRoot "release"
$DummyApiKey = "sk-" + "1234567890abcdef" + "1234567890abcdef"

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

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = ConvertTo-SimCommandLine -Arguments $Arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    foreach ($key in $Environment.Keys) {
        $psi.EnvironmentVariables[$key] = [string]$Environment[$key]
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()

    if ($InputText) {
        $proc.StandardInput.Write($InputText)
    }
    $proc.StandardInput.Close()

    $finished = $proc.WaitForExit($TimeoutSec * 1000)
    if (-not $finished) {
        try { $proc.Kill() } catch { }
        throw "$Name timed out after ${TimeoutSec}s"
    }

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
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
            "scripts/build-release.ps1",
            "scripts/simulate-user-release.ps1",
            "CLAUDE.md",
            ".gitignore",
            "report.txt"
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
            "Get-DeepSeekConfigStatus"
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
    $menuRun = Invoke-SimCommand -Name "Start-Here.ps1 menu" -FileName $powerShellExe -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $releaseRoot "Start-Here.ps1")
    ) -InputText "Y`r`n5`r`n" -WorkingDirectory $releaseRoot -Environment $envVars
    [void]$runs.Add($menuRun)

    $advancedRun = Invoke-SimCommand -Name "Start-Here.ps1 advanced menu" -FileName $powerShellExe -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $releaseRoot "Start-Here.ps1")
    ) -InputText "Y`r`n4`r`n3`r`n5`r`n" -WorkingDirectory $releaseRoot -Environment $envVars
    [void]$runs.Add($advancedRun)

    [void]$runs.Add((Invoke-SimCommand -Name "Start-Install.cmd" -FileName $cmdExe -Arguments @("/c", "Start-Install.cmd") -InputText "Y`r`n5`r`n`r`n" -WorkingDirectory $releaseRoot -Environment $envVars))
    [void]$runs.Add((Invoke-SimCommand -Name "开始安装.cmd" -FileName $cmdExe -Arguments @("/c", "开始安装.cmd") -InputText "Y`r`n5`r`n`r`n" -WorkingDirectory $releaseRoot -Environment $envVars))

    $startHereLogs = Get-ChildItem -Path (Join-Path $releaseRoot "logs") -Filter "start-here-*.log" -ErrorAction SilentlyContinue
    $startHereLogText = ($startHereLogs | ForEach-Object { Get-Content -Path $_.FullName -Raw -Encoding UTF8 }) -join "`n"
    if ($startHereLogText -notmatch "用户选择: 退出") {
        throw "Start-Here did not reach menu exit path"
    }
    if ($startHereLogText -notmatch "用户选择: 高级选项" -or $startHereLogText -notmatch "用户选择: 从高级选项返回主菜单") {
        throw "Start-Here did not exercise advanced menu return path"
    }

    [void]$runs.Add((Invoke-SimCommand -Name "Run-Diagnostics.cmd" -FileName $cmdExe -Arguments @("/c", "Run-Diagnostics.cmd") -InputText "`r`n" -WorkingDirectory $releaseRoot -Environment $envVars -TimeoutSec 180))
    [void]$runs.Add((Invoke-SimCommand -Name "一键诊断.cmd" -FileName $cmdExe -Arguments @("/c", "一键诊断.cmd") -InputText "`r`n" -WorkingDirectory $releaseRoot -Environment $envVars -TimeoutSec 180))

    [void]$runs.Add((Invoke-SimCommand -Name "Restore-Config.cmd" -FileName $cmdExe -Arguments @("/c", "Restore-Config.cmd") -InputText "4`r`n`r`n" -WorkingDirectory $releaseRoot -Environment $envVars))
    [void]$runs.Add((Invoke-SimCommand -Name "恢复或卸载配置.cmd" -FileName $cmdExe -Arguments @("/c", "恢复或卸载配置.cmd") -InputText "4`r`n`r`n" -WorkingDirectory $releaseRoot -Environment $envVars))

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
        "开始安装.cmd",
        "Run-Diagnostics.cmd",
        "一键诊断.cmd",
        "Restore-Config.cmd",
        "恢复或卸载配置.cmd"
    )) {
        Copy-Item -Path (Join-Path $releaseRoot $launcher) -Destination (Join-Path $missingDir $launcher) -Force
        $run = Invoke-SimCommand -Name "missing package: $launcher" -FileName $cmdExe -Arguments @("/c", $launcher) -InputText "`r`n" -WorkingDirectory $missingDir -ExpectedExitCode 1 -Environment $envVars
        if ($run.Combined -notmatch "Please extract the full ZIP package first") {
            throw "$launcher did not show extract-full-ZIP guidance"
        }
        [void]$runs.Add($run)
        Remove-Item -Path (Join-Path $missingDir $launcher) -Force
    }

    Assert-NoBadRuntimeText -Runs $runs -ReleaseRoot $releaseRoot -DummyKey $DummyApiKey

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
