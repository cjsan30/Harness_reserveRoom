# Masks credential values before runtime output is written to logs or reports.
# Pattern based plus exact values of sensitive-looking environment variables. It
# lowers the chance that a public repository or shared report leaks a secret; it
# is not a guarantee that arbitrary secrets are detected.

$script:HarnessRedactionMarker = '[REDACTED]'
$script:HarnessSensitiveKeyPattern = '[\w.-]*(?:api[_-]?key|access[_-]?key|secret|token|password|passwd|pwd|credential|private[_-]?key)[\w.-]*'

function Get-HarnessSensitiveEnvironmentValues {
    $values = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $name = [string]$entry.Key
        $value = [string]$entry.Value
        if ($name -notmatch '(?i)(TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|CREDENTIAL)') { continue }
        # Short or structural values (flags, paths, numbers) would mask ordinary text.
        if ($value.Length -lt 8 -or $value -match '^\d+$' -or $value -match '^(?i:true|false|null|none)$') { continue }
        $values.Add($value) | Out-Null
    }
    # Longest first so a value containing another is masked whole. Deduplicate by
    # value first: Sort-Object -Unique with -Property drops equal-length values in PS7.
    return @($values | Select-Object -Unique | Sort-Object -Property Length -Descending)
}

function Test-HarnessRedactableValue([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    if ($Value -eq $script:HarnessRedactionMarker) { return $false }
    # Usage counters such as "input_tokens": 120 and booleans are not secrets.
    if ($Value -match '^-?\d+(?:\.\d+)?$' -or $Value -match '^(?i:true|false|null|none|undefined)$') { return $false }
    return $true
}

function Protect-HarnessSecretText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $marker = $script:HarnessRedactionMarker
    $result = $Text

    foreach ($value in (Get-HarnessSensitiveEnvironmentValues)) {
        $result = $result.Replace($value, $marker)
    }

    # Private key blocks, whole.
    $result = [regex]::Replace($result, '-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----[\s\S]*?(?:-----END (?:[A-Z]+ )?PRIVATE KEY-----|$)', '-----BEGIN PRIVATE KEY-----' + $marker + '-----END PRIVATE KEY-----')

    # Well-known token formats.
    $tokenPatterns = @(
        '\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}',
        '\bgh[pousr]_[A-Za-z0-9]{20,}',
        '\bgithub_pat_[A-Za-z0-9_]{20,}',
        '\bglpat-[A-Za-z0-9_-]{20,}',
        '\bxox[abposr]-[A-Za-z0-9-]{10,}',
        '\bAKIA[0-9A-Z]{16}\b',
        '\bAIza[0-9A-Za-z_-]{35}\b',
        '\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'
    )
    foreach ($pattern in $tokenPatterns) {
        $result = [regex]::Replace($result, $pattern, $marker)
    }

    # Authorization headers.
    $result = [regex]::Replace($result, '(?i)\b((?:Bearer|Basic|token)\s+)([A-Za-z0-9._~+/=-]{12,})', {
            param($match)
            return $match.Groups[1].Value + $marker
        })

    # URL user info: scheme://user:password@host
    $result = [regex]::Replace($result, '(?i)\b([a-z][a-z0-9+.-]*://[^\s/:@]+:)([^\s/@]+)(@)', {
            param($match)
            return $match.Groups[1].Value + $marker + $match.Groups[3].Value
        })

    # JSON: "api_key": "value"
    $result = [regex]::Replace($result, '(?i)("' + $script:HarnessSensitiveKeyPattern + '"\s*:\s*")((?:[^"\\]|\\.)*)(")', {
            param($match)
            if (-not (Test-HarnessRedactableValue $match.Groups[2].Value)) { return $match.Value }
            return $match.Groups[1].Value + $marker + $match.Groups[3].Value
        })

    # Assignments: API_KEY=value, password: value, --token value is left to the patterns above.
    $result = [regex]::Replace($result, '(?i)(?<![\w"])(' + $script:HarnessSensitiveKeyPattern + ')(\s*[:=]\s*)(["'']?)([^\s"'',;]+)', {
            param($match)
            if (-not (Test-HarnessRedactableValue $match.Groups[4].Value)) { return $match.Value }
            return $match.Groups[1].Value + $match.Groups[2].Value + $match.Groups[3].Value + $marker
        })

    return $result
}
