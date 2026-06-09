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
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -and $bytes[2] -ne 0xBF) {
        throw "$($File.FullName) is missing UTF-8 BOM"
    }
}
