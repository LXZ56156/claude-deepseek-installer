# Release-time sensitive-content scanning helpers.

Set-StrictMode -Version Latest

function Redact-SensitiveMatch {
    param([AllowNull()][string]$RawMatch)

    if ([string]::IsNullOrEmpty($RawMatch)) {
        return '<redacted-api-key>'
    }

    $keyMatch = [regex]::Match($RawMatch, 'sk-[A-Za-z0-9]{20,}')
    if ($keyMatch.Success) {
        $key = [string]$keyMatch.Value
        $suffix = if ($key.Length -ge 4) { $key.Substring($key.Length - 4) } else { '' }
        if ($suffix) { return "<redacted-api-key: suffix=$suffix>" }
        return '<redacted-api-key>'
    }

    if ($RawMatch -match '(?i)(API[_ -]?KEY|AUTH_TOKEN|TOKEN|SECRET|settings\.json)') {
        return '<redacted-sensitive-match>'
    }

    $normalized = ($RawMatch -replace '\s+', ' ').Trim()
    if ($normalized.Length -le 24) { return $normalized }
    return ($normalized.Substring(0, 12) + '...' + $normalized.Substring($normalized.Length - 4))
}

function Get-SensitiveMatchLineNumber {
    param(
        [AllowNull()][string]$Content,
        [int]$Index
    )

    if ([string]::IsNullOrEmpty($Content) -or $Index -le 0) { return 1 }
    $boundedIndex = [Math]::Min($Index, $Content.Length)
    return 1 + ([regex]::Matches($Content.Substring(0, $boundedIndex), "`n")).Count
}

function Get-SensitiveMatchType {
    param(
        [string]$Pattern,
        [AllowNull()][string]$MatchText
    )

    if ($Pattern -match '^sk-') { return 'api-key' }
    if ($MatchText -match 'ANTHROPIC_AUTH_TOKEN') { return 'ANTHROPIC_AUTH_TOKEN' }
    if ($MatchText -match 'DEEPSEEK_API_KEY') { return 'DEEPSEEK_API_KEY' }
    if ($MatchText -match 'CCDI_API_KEY') { return 'CCDI_API_KEY' }
    return 'sensitive-pattern'
}

function Test-IsSafePlaceholderKey {
    param(
        [string]$KeyPart,
        [string[]]$SafePlaceholders
    )

    foreach ($safe in @($SafePlaceholders)) {
        if ($KeyPart -ceq $safe) { return $true }
    }

    return $false
}

function Add-ApiKeyHitsFromContent {
    param(
        [AllowNull()][string]$Content,
        [string]$DisplayPath,
        [System.Collections.Generic.List[object]]$Hits,
        [string[]]$DangerPatterns,
        [string[]]$SafePlaceholders
    )

    if ([string]::IsNullOrEmpty($Content)) { return }

    foreach ($pattern in @($DangerPatterns)) {
        $matches = [regex]::Matches($Content, $pattern)
        foreach ($match in $matches) {
            $candidate = $match.Value.Trim()
            $keyMatches = [regex]::Matches($candidate, 'sk-[A-Za-z0-9]{20,}')

            foreach ($keyMatch in $keyMatches) {
                $keyPart = $keyMatch.Value
                if (Test-IsSafePlaceholderKey -KeyPart $keyPart -SafePlaceholders $SafePlaceholders) {
                    continue
                }

                [void]$Hits.Add([PSCustomObject]@{
                    File     = $DisplayPath
                    Line     = Get-SensitiveMatchLineNumber -Content $Content -Index $match.Index
                    Type     = Get-SensitiveMatchType -Pattern $pattern -MatchText $candidate
                    Pattern  = $pattern
                    Redacted = Redact-SensitiveMatch -RawMatch $candidate
                })
            }
        }
    }
}
