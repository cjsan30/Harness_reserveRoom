# Intake is a specification, never a credential store. The sensitive section
# accepts a variable name at the start of each line and discards everything else.
function ConvertTo-SafeHarnessIntake {
    param([AllowEmptyCollection()][string[]]$Lines)
    $safe = New-Object 'System.Collections.Generic.List[string]'
    $inSecrets = $false
    foreach ($line in $Lines) {
        if ($line -match '^\s*#{1,2}\s+') {
            $inSecrets = $line -match '^\s*##\s+Secrets And Access\s*$'
            $safe.Add($line)
            if ($inSecrets) { $safe.Add('- Values and free text omitted. Supply credentials only through the local environment or a secret store.') }
            continue
        }
        if ($inSecrets) {
            # Do not scan arbitrary uppercase words: those may be credential values.
            if ($line -cmatch '^\s*(?:[-*]\s*)?`?([A-Z][A-Z0-9_]{1,63})`?\s*(?:[:=].*)?$') {
                $safe.Add('- ' + $Matches[1])
            }
        } else { $safe.Add($line) }
    }
    return $safe.ToArray()
}

function Assert-HarnessIntakeHasNoCredentials {
    param([AllowEmptyCollection()][string[]]$Lines)
    $text = $Lines -join "`n"
    # Fail without including the offending line/value in the error. This catches
    # common misplaced credentials; it is not an arbitrary-secret detector.
    $patterns = @(
        '(?i)\b(?:sk-(?:proj-)?[a-z0-9_-]{16,}|gh[pousr]_[a-z0-9]{20,}|github_pat_[a-z0-9_]{20,})\b',
        '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
        '(?im)^\s*[-*]?\s*["''`]?\w*(?:api[_-]?key|token|password|secret)\w*["''`]?\s*[:=]\s*["'']?[^\s"''#][^\r\n]*',
        '(?i)\b[a-z][a-z0-9+.-]*://[^\s/:]+:[^\s/@]+@'
    )
    foreach ($pattern in $patterns) {
        if ($text -match $pattern) { throw 'possible credential outside Secrets And Access; remove values before processing intake' }
    }
}
