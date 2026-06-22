[CmdletBinding()]
param(
    [string]$CredentialTarget = "CCDI_ACCEPTANCE_DEEPSEEK_API_KEY",
    [switch]$Delete
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$driverSource = Join-Path $PSScriptRoot "lib\ConPtyAcceptanceHost.cs"
if (-not (Test-Path -LiteralPath $driverSource -PathType Leaf)) {
    throw "Credential helper source missing: $driverSource"
}
Add-Type -Path $driverSource

if ($Delete) {
    [Ccdi.Acceptance.WindowsCredential]::DeleteGeneric($CredentialTarget)
    Write-Host "Acceptance credential deleted: $CredentialTarget" -ForegroundColor Green
    exit 0
}

$secure = Read-Host "请输入验收专用 DeepSeek API Key（不会回显）" -AsSecureString
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
$secret = $null
try {
    $secret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    if ([string]::IsNullOrWhiteSpace($secret) -or $secret -notmatch '^sk-.{20,}$') {
        throw "输入内容不像有效的 DeepSeek API Key，未写入凭据管理器"
    }
    [Ccdi.Acceptance.WindowsCredential]::WriteGeneric($CredentialTarget, "DeepSeek acceptance", $secret)
    Write-Host "Acceptance credential saved: $CredentialTarget" -ForegroundColor Green
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    $secret = $null
}
