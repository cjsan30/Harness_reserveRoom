# Failure classification for worker attempts. The class decides whether an attempt
# counts toward max_attempts_per_assignment and whether the dispatcher may retry.
# Every launched invocation still counts toward the global invocation, token and
# time budgets; classification never refunds or deletes a usage record.
$script:HarnessFailureClasses = @('implementation','environment','permission','provider','needs_input')
$script:HarnessProviderFailureKinds = @('usage_limit','auth','rate_limit','overloaded','unknown')
$script:HarnessKnownErrorSources = @('validation','worker','provider')
# A timed-out worker that printed nothing for this long was waiting on a hung
# command (for example a test waiting for Docker), not working on the task.
$script:HarnessIdleTimeoutSeconds = 300
$script:HarnessNeedsInputMarker = 'HARNESS_NEEDS_INPUT:'

function Get-HarnessFailureStateDirectory([string]$RootDir) {
    return Resolve-HarnessEnginePath $RootDir 'harness/state/failures' 'failure history'
}

function Get-HarnessAttemptGrantDirectory([string]$RootDir) {
    return Resolve-HarnessEnginePath $RootDir 'harness/state/attempt_grants' 'attempt grants'
}

function Assert-HarnessKnownErrorEntry($Entry, [string]$Source) {
    if ($null -eq $Entry -or $Entry.id -isnot [string] -or $Entry.id -cnotmatch '^[a-z0-9][a-z0-9-]{1,63}$') { throw "invalid known error id in $Source" }
    foreach ($field in $Entry.PSObject.Properties.Name) {
        if ($field -cnotin @('id','class','kind','sources','match_any','repair','note')) { throw "unknown known error field '$field' in $Source" }
    }
    if ($Entry.class -cnotin $script:HarnessFailureClasses -or $Entry.class -ceq 'implementation') { throw "invalid known error class for $($Entry.id) in $Source" }
    if ($Entry.class -ceq 'provider' -and $Entry.kind -cnotin $script:HarnessProviderFailureKinds) { throw "provider known error $($Entry.id) needs a valid kind in $Source" }
    $sources = @($Entry.sources)
    if ($sources.Count -eq 0 -or @($sources | Where-Object { $_ -cnotin $script:HarnessKnownErrorSources }).Count -gt 0) { throw "invalid known error sources for $($Entry.id) in $Source" }
    $texts = @($Entry.match_any)
    if ($texts.Count -eq 0 -or @($texts | Where-Object { $_ -isnot [string] -or $_.Trim().Length -lt 4 }).Count -gt 0) { throw "known error $($Entry.id) needs match texts of at least 4 characters in $Source" }
    if ($null -ne $Entry.repair -and ($Entry.repair -isnot [string] -or $Entry.repair -cnotmatch '^[a-z0-9][a-z0-9-]{1,63}$')) { throw "invalid repair id for $($Entry.id) in $Source" }
}

function Get-HarnessKnownErrorCatalog([string]$RootDir) {
    $entries = [ordered]@{}
    $files = @(
        @{ Path = (Join-Path (Get-HarnessEngineRoot $RootDir) 'configs/known_errors.json'); Label = 'engine known_errors.json' },
        @{ Path = (Resolve-HarnessEnginePath $RootDir 'harness/project/configs/known_errors.json' 'project known errors'); Label = 'project known_errors.json' }
    )
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file.Path)) { continue }
        try { $catalog = [IO.File]::ReadAllText($file.Path) | ConvertFrom-Json } catch { throw "invalid JSON in $($file.Label)" }
        if ($catalog.version -ne 1 -or $null -eq $catalog.entries) { throw "unsupported $($file.Label)" }
        foreach ($entry in @($catalog.entries)) {
            Assert-HarnessKnownErrorEntry $entry $file.Label
            # A project entry with the same id replaces the engine default.
            if ($entries.Contains($entry.id)) { $entries.Remove($entry.id) }
            $entries[$entry.id] = $entry
        }
    }
    return @($entries.Values)
}

function Find-HarnessKnownError($Catalog, [string]$Source, [string]$Text, [string[]]$Classes) {
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    foreach ($entry in @($Catalog)) {
        if ($Classes -and $entry.class -cnotin $Classes) { continue }
        if (@($entry.sources) -cnotcontains $Source) { continue }
        foreach ($match in @($entry.match_any)) {
            if ($Text.IndexOf($match, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $entry }
        }
    }
    return $null
}

function ConvertTo-HarnessFailureLine([string]$Line) {
    $value = $Line.Trim()
    # Keep only file names so the same error in another checkout gives the same signature.
    $value = [Regex]::Replace($value, '(?:[A-Za-z]:)?(?:[\\/][^\\/\s:''"()\[\]]+)+[\\/]([^\\/\s:''"()\[\]]+)', '$1')
    $value = [Regex]::Replace($value, '\b[0-9a-f]{12,}\b', '#')
    $value = [Regex]::Replace($value, '\d+', '#')
    $value = [Regex]::Replace($value, '\s+', ' ')
    return $value.ToLowerInvariant()
}

function Get-HarnessFailureSignature([AllowEmptyString()][string]$Text, [string]$Fallback = 'no-output') {
    # Generic build-tool lines are skipped so the signature is driven by the specific error.
    $generic = '(?i)^(?:BUILD FAILED|FAILURE: Build failed|\* What went wrong|\* Try:|> Run with --|> Get more help|Execution failed for task|There were failing tests|[#\d]+ tests? completed|See the report at|Deprecated Gradle features)'
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($raw in @(([string]$Text) -split '\r?\n')) {
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line -match $generic) { continue }
        if ($line -notmatch '(?i)error|failed|exception|cannot find symbol|expected') { continue }
        $normalized = ConvertTo-HarnessFailureLine $line
        if ($normalized.Length -gt 240) { $normalized = $normalized.Substring(0, 240) }
        if (-not $lines.Contains($normalized)) { $lines.Add($normalized) | Out-Null }
        if ($lines.Count -ge 5) { break }
    }
    if ($lines.Count -eq 0) {
        $tail = @(([string]$Text) -split '\r?\n' | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -Last 3)
        foreach ($line in $tail) { $lines.Add((ConvertTo-HarnessFailureLine $line)) | Out-Null }
    }
    if ($lines.Count -eq 0) { $lines.Add($Fallback) | Out-Null }
    $joined = $lines.ToArray() -join "`n"
    return [pscustomobject]@{ id = (Get-HarnessTextHash $joined).Substring(0, 16); lines = $lines.ToArray() }
}

function Get-HarnessLatestValidationEvidence([string]$RootDir, [string]$AssignmentId, [string]$InvocationId) {
    $directory = Get-AssignmentEvidenceDirectory $RootDir
    if (-not (Test-Path -LiteralPath $directory)) { return $null }
    $latest = $null
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File)) {
        try { $evidence = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json } catch { continue }
        if ($evidence.assignment_id -cne $AssignmentId -or $evidence.invocation_id -cne $InvocationId) { continue }
        if ($null -eq $latest -or [string]$evidence.started_at -gt [string]$latest.started_at) { $latest = $evidence }
    }
    return $latest
}

function Get-HarnessAttemptFacts([string]$RootDir, $WorkerRecord, [string]$LogPath, [AllowEmptyString()][string]$LastMessage = '') {
    $providerMessages = New-Object 'System.Collections.Generic.List[string]'
    $denials = New-Object 'System.Collections.Generic.List[string]'
    $resultSubtype = $null
    $finalText = ''
    if (-not [string]::IsNullOrWhiteSpace($LogPath) -and (Test-Path -LiteralPath $LogPath)) {
        foreach ($line in [IO.File]::ReadLines($LogPath)) {
            if (-not $line.TrimStart().StartsWith('{')) { continue }
            try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($event -isnot [pscustomobject] -or $event.type -isnot [string]) { continue }
            if ($event.type -ceq 'error' -and $event.message -is [string]) { $providerMessages.Add($event.message) | Out-Null }
            if ($event.type -ceq 'turn.failed' -and $null -ne $event.error -and $event.error.message -is [string]) { $providerMessages.Add($event.error.message) | Out-Null }
            if ($event.type -cne 'result') { continue }
            if ($event.subtype -is [string]) { $resultSubtype = $event.subtype }
            if ($event.result -is [string]) { $finalText = $event.result }
            # Text in an error result comes from the provider, not from the worker's tools.
            if ($event.is_error -is [bool] -and $event.is_error) {
                if ($event.result -is [string]) { $providerMessages.Add($event.result) | Out-Null }
                foreach ($item in @($event.errors)) { if ($item -is [string]) { $providerMessages.Add($item) | Out-Null } }
            }
            foreach ($denial in @($event.permission_denials)) {
                if ($null -eq $denial) { continue }
                $detail = [string]$denial.tool_name
                if ($null -ne $denial.tool_input -and $null -ne $denial.tool_input.PSObject.Properties['command']) { $detail += ': ' + [string]$denial.tool_input.command }
                elseif ($null -ne $denial.tool_input -and $null -ne $denial.tool_input.PSObject.Properties['file_path']) { $detail += ': ' + [string]$denial.tool_input.file_path }
                $detail = Protect-HarnessSecretText $detail
                if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) }
                if (-not $denials.Contains($detail)) { $denials.Add($detail) | Out-Null }
            }
        }
    }
    $needsInput = $null
    foreach ($text in @($LastMessage, $finalText)) {
        foreach ($line in @(([string]$text) -split '\r?\n')) {
            $trimmed = $line.Trim()
            if ($trimmed.StartsWith($script:HarnessNeedsInputMarker, [StringComparison]::Ordinal)) {
                $needsInput = Protect-HarnessSecretText ($trimmed.Substring($script:HarnessNeedsInputMarker.Length).Trim())
                if ($needsInput.Length -gt 300) { $needsInput = $needsInput.Substring(0, 300) }
                break
            }
        }
        if ($null -ne $needsInput) { break }
    }
    $evidence = Get-HarnessLatestValidationEvidence $RootDir $WorkerRecord.assignment_id $WorkerRecord.invocation_id
    $validationLog = ''
    if ($null -ne $evidence -and $evidence.status -cne 'pass' -and $evidence.log -is [string]) {
        try {
            $path = Resolve-ProjectPath $RootDir $evidence.log 'validation log'
            if (Test-Path -LiteralPath $path) { $validationLog = [IO.File]::ReadAllText($path) }
        } catch { $validationLog = '' }
    }
    $timedOut = ($null -ne $WorkerRecord.PSObject.Properties['timed_out'] -and $WorkerRecord.timed_out -eq $true)
    $idleSeconds = $null
    if ($null -ne $WorkerRecord.PSObject.Properties['idle_seconds_at_exit'] -and $null -ne $WorkerRecord.idle_seconds_at_exit) { $idleSeconds = [double]$WorkerRecord.idle_seconds_at_exit }
    $result = $WorkerRecord.provider_result
    return [pscustomobject]@{
        provider_error_kind = $(if ($null -ne $result) { $result.error_kind } else { 'unknown' })
        exit_code = $WorkerRecord.exit_code
        timed_out = $timedOut
        idle_seconds = $idleSeconds
        result_subtype = $resultSubtype
        provider_messages = $providerMessages.ToArray()
        permission_denials = $denials.ToArray()
        needs_input = $needsInput
        final_text = $finalText
        validation_ran = ($null -ne $evidence)
        validation_status = $(if ($null -ne $evidence) { $evidence.status } else { $null })
        validation_log = $validationLog
        worker_log = $(if (-not [string]::IsNullOrWhiteSpace($LogPath) -and (Test-Path -LiteralPath $LogPath)) { [IO.File]::ReadAllText($LogPath) } else { '' })
    }
}

function New-HarnessFailureClassification([string]$Class, [string]$Kind, [string]$Summary, $Entry = $null, $Signature = $null, [string[]]$Details = @()) {
    return [pscustomobject]@{
        class = $Class; kind = $Kind; catalog_id = $(if ($null -ne $Entry) { $Entry.id } else { $null })
        repair = $(if ($null -ne $Entry) { $Entry.repair } else { $null })
        counts_toward_assignment_limit = ($Class -ceq 'implementation')
        signature = $(if ($null -ne $Signature) { $Signature.id } else { $null })
        signature_lines = $(if ($null -ne $Signature) { @($Signature.lines) } else { @() })
        summary = $Summary; details = @($Details)
    }
}

function Get-HarnessAttemptClassification($Catalog, $Facts) {
    if ($Facts.timed_out) {
        if ($null -ne $Facts.idle_seconds -and $Facts.idle_seconds -ge $script:HarnessIdleTimeoutSeconds) {
            return New-HarnessFailureClassification 'environment' 'hung_command' ("worker timed out after printing nothing for {0:N0} seconds; a command was probably waiting on the environment" -f $Facts.idle_seconds)
        }
        return New-HarnessFailureClassification 'implementation' 'timeout' 'worker was still working when max_invocation_seconds was reached' $null (Get-HarnessFailureSignature '' 'timeout')
    }
    if (@($Facts.permission_denials).Count -gt 0) {
        return New-HarnessFailureClassification 'permission' 'denied' 'the provider denied tool use that the worker needed; review the allowed commands' $null $null @($Facts.permission_denials)
    }
    $providerText = @($Facts.provider_messages) -join "`n"
    $providerEntry = Find-HarnessKnownError $Catalog 'provider' $providerText @('provider')
    if ($null -ne $providerEntry) {
        return New-HarnessFailureClassification 'provider' $providerEntry.kind $providerEntry.note $providerEntry
    }
    if ($Facts.result_subtype -ceq 'error_max_turns') {
        return New-HarnessFailureClassification 'implementation' 'max_turns' 'worker used all of its turns before finishing' $null (Get-HarnessFailureSignature '' 'max-turns')
    }
    if ($Facts.provider_error_kind -cin @('process_exit','provider_error','provider_protocol') -and -not $Facts.validation_ran) {
        $detail = @($Facts.provider_messages | ForEach-Object { $text = Protect-HarnessSecretText $_; if ($text.Length -gt 200) { $text.Substring(0, 200) } else { $text } } | Select-Object -First 3)
        return New-HarnessFailureClassification 'provider' 'unknown' ("provider run failed ({0}) before any validation" -f $Facts.provider_error_kind) $null $null $detail
    }
    if (-not [string]::IsNullOrWhiteSpace($Facts.needs_input)) {
        return New-HarnessFailureClassification 'needs_input' 'missing_information' 'worker stopped because required information is missing' $null $null @($Facts.needs_input)
    }
    $environmentEntry = Find-HarnessKnownError $Catalog 'validation' $Facts.validation_log @('environment')
    if ($null -eq $environmentEntry) { $environmentEntry = Find-HarnessKnownError $Catalog 'worker' $Facts.worker_log @('environment') }
    if ($null -ne $environmentEntry) {
        return New-HarnessFailureClassification 'environment' $environmentEntry.id $environmentEntry.note $environmentEntry
    }
    if ($Facts.validation_ran) {
        return New-HarnessFailureClassification 'implementation' 'validation_failed' 'validation ran and failed' $null (Get-HarnessFailureSignature $Facts.validation_log 'validation-failed')
    }
    return New-HarnessFailureClassification 'implementation' 'not_validated' 'worker finished without passing validation' $null (Get-HarnessFailureSignature '' ('no-validation-' + [string]$Facts.result_subtype))
}

function Read-HarnessFailureHistory([string]$RootDir, [string]$AssignmentId) {
    $id = Assert-SafePathToken $AssignmentId 'assignment id'
    $path = Join-Path (Get-HarnessFailureStateDirectory $RootDir) ($id + '.json')
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ version = 1; assignment_id = $AssignmentId; attempts = @() } }
    try { $history = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { throw 'invalid failure history JSON; execution refused' }
    if ($history.version -ne 1 -or $history.assignment_id -cne $AssignmentId -or
        -not [string]::Equals([IO.Path]::GetFullPath($RootDir), $history.root, (Get-HarnessPathComparison))) { throw 'invalid failure history; execution refused' }
    foreach ($attempt in @($history.attempts)) {
        if ($attempt.invocation_id -cnotmatch '^[a-f0-9]{32}$' -or $attempt.class -cnotin $script:HarnessFailureClasses -or
            $attempt.counts_toward_assignment_limit -isnot [bool] -or ($attempt.class -ceq 'implementation') -ne $attempt.counts_toward_assignment_limit) { throw 'invalid failure history entry; execution refused' }
    }
    return $history
}

function Save-HarnessAttemptClassification([string]$RootDir, $WorkerRecord, $Classification) {
    $history = Read-HarnessFailureHistory $RootDir $WorkerRecord.assignment_id
    $attempts = @($history.attempts | Where-Object { $_.invocation_id -cne $WorkerRecord.invocation_id })
    $entry = [pscustomobject]@{
        invocation_id = $WorkerRecord.invocation_id; owner = $WorkerRecord.owner; classified_at = [DateTime]::UtcNow.ToString('o')
        class = $Classification.class; kind = $Classification.kind; catalog_id = $Classification.catalog_id; repair = $Classification.repair
        counts_toward_assignment_limit = $Classification.counts_toward_assignment_limit
        signature = $Classification.signature; signature_lines = @($Classification.signature_lines)
        summary = $Classification.summary; details = @($Classification.details)
        excerpt = @($(if ($null -ne $Classification.PSObject.Properties['excerpt']) { $Classification.excerpt } else { @() }))
        worker_note = @($(if ($null -ne $Classification.PSObject.Properties['worker_note']) { $Classification.worker_note } else { @() }))
    }
    $saved = [pscustomobject]@{ version = 1; root = [IO.Path]::GetFullPath($RootDir); assignment_id = $WorkerRecord.assignment_id; attempts = @($attempts + $entry) }
    $path = Join-Path (Get-HarnessFailureStateDirectory $RootDir) ((Assert-SafePathToken $WorkerRecord.assignment_id 'assignment id') + '.json')
    Write-Utf8File $path ($saved | ConvertTo-Json -Depth 8)
    $null = Write-HarnessFailureMemo $RootDir $WorkerRecord.assignment_id
    return $entry
}

function Invoke-HarnessAttemptClassification([string]$RootDir, $WorkerRecord, [string]$LogPath, [AllowEmptyString()][string]$LastMessage = '') {
    # Classification problems fall back to a counted implementation failure (fail closed).
    $facts = $null
    try {
        $facts = Get-HarnessAttemptFacts $RootDir $WorkerRecord $LogPath $LastMessage
        $classification = Get-HarnessAttemptClassification (Get-HarnessKnownErrorCatalog $RootDir) $facts
    } catch {
        $classification = New-HarnessFailureClassification 'implementation' 'unclassified' ('failure could not be classified: ' + $_.Exception.Message) $null (Get-HarnessFailureSignature '' 'unclassified')
    }
    if ($null -ne $facts) {
        $classification | Add-Member -NotePropertyName excerpt -NotePropertyValue @(Get-HarnessFailureExcerpt $facts.validation_log) -Force
        $classification | Add-Member -NotePropertyName worker_note -NotePropertyValue @(Get-HarnessWorkerFailureNote ($LastMessage + "`n`n" + $facts.final_text)) -Force
    }
    return Save-HarnessAttemptClassification $RootDir $WorkerRecord $classification
}

function Read-HarnessAttemptGrants([string]$RootDir, [string]$AssignmentId) {
    $id = Assert-SafePathToken $AssignmentId 'assignment id'
    $path = Join-Path (Get-HarnessAttemptGrantDirectory $RootDir) ($id + '.json')
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try { $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { throw 'invalid attempt grant JSON; execution refused' }
    if ($saved.version -ne 1 -or $saved.assignment_id -cne $AssignmentId -or
        -not [string]::Equals([IO.Path]::GetFullPath($RootDir), $saved.root, (Get-HarnessPathComparison))) { throw 'invalid attempt grant file; execution refused' }
    foreach ($grant in @($saved.grants)) {
        if (-not (Test-HarnessUsageInteger $grant.extra) -or $grant.extra -lt 1 -or $grant.extra -gt 10 -or [string]::IsNullOrWhiteSpace($grant.reason)) { throw 'invalid attempt grant; execution refused' }
    }
    return @($saved.grants)
}

function Add-HarnessAttemptGrant([string]$RootDir, [string]$AssignmentId, [int]$Extra, [string]$Reason, [string]$Source = 'cli') {
    if ($Extra -lt 1 -or $Extra -gt 10) { throw 'extra attempts must be between 1 and 10' }
    if ([string]::IsNullOrWhiteSpace($Reason)) { throw 'a reason is required for an attempt grant' }
    $Reason = Protect-HarnessSecretText $Reason.Trim()
    if ($Reason.Length -gt 500) { $Reason = $Reason.Substring(0, 500) }
    $lease = Acquire-HarnessLock (Get-HarnessLockRoot $RootDir) 'execution_budget'
    if ($null -eq $lease) { throw 'execution accounting is busy; grant not recorded' }
    try {
        $grants = @(Read-HarnessAttemptGrants $RootDir $AssignmentId)
        $status = Get-HarnessAssignmentAttemptStatus $RootDir $AssignmentId
        $grant = [pscustomobject]@{ extra = $Extra; reason = $Reason; source = $Source; granted_at = [DateTime]::UtcNow.ToString('o'); counted_at_grant = $status.counted; limit_before = $status.limit }
        $saved = [pscustomobject]@{ version = 1; root = [IO.Path]::GetFullPath($RootDir); assignment_id = $AssignmentId; grants = @($grants + $grant) }
        Write-Utf8File (Join-Path (Get-HarnessAttemptGrantDirectory $RootDir) ((Assert-SafePathToken $AssignmentId 'assignment id') + '.json')) ($saved | ConvertTo-Json -Depth 6)
    } finally { Release-HarnessLock $lease }
    return Get-HarnessAssignmentAttemptStatus $RootDir $AssignmentId
}

function Get-HarnessAssignmentAttemptStatus([string]$RootDir, [string]$AssignmentId, $Records = $null, $Policy = $null) {
    if ($null -eq $Records) { $Records = @(Read-HarnessUsageRecords $RootDir) }
    if ($null -eq $Policy) { $Policy = Get-HarnessExecutionPolicy $RootDir }
    $history = Read-HarnessFailureHistory $RootDir $AssignmentId
    $notCounted = @{}
    foreach ($attempt in @($history.attempts)) { if (-not $attempt.counts_toward_assignment_limit) { $notCounted[$attempt.invocation_id] = $attempt.class } }
    $invocations = @($Records | Where-Object { $_.assignment_id -ceq $AssignmentId })
    # An invocation without a classification (in flight, crashed, or recorded by an
    # older engine) counts as an implementation attempt.
    $counted = @($invocations | Where-Object { -not $notCounted.ContainsKey($_.invocation_id) }).Count
    $extra = 0
    foreach ($grant in @(Read-HarnessAttemptGrants $RootDir $AssignmentId)) { $extra += [int]$grant.extra }
    $limit = $null
    if ($null -ne $Policy.max_attempts_per_assignment) { $limit = [int]$Policy.max_attempts_per_assignment + $extra }
    return [pscustomobject]@{
        assignment_id = $AssignmentId; invocations = $invocations.Count; counted = $counted
        not_counted = ($invocations.Count - $counted); policy_limit = $Policy.max_attempts_per_assignment
        granted_extra = $extra; limit = $limit
        remaining = $(if ($null -ne $limit) { [Math]::Max(0, $limit - $counted) } else { $null })
    }
}

function Get-HarnessFailureDecision($Classification, $History) {
    # stop_* decisions end the plan run and keep the assignment for the operator.
    switch ($Classification.class) {
        'implementation' {
            $previous = @($History.attempts | Where-Object { $_.class -ceq 'implementation' -and $_.invocation_id -cne $Classification.invocation_id } | Select-Object -Last 1)
            if ($previous.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($Classification.signature) -and $previous[0].signature -ceq $Classification.signature) {
                return [pscustomobject]@{ action = 'stop_repeated'; reason = "the same failure repeated (signature $($Classification.signature)); retrying again would likely waste usage" }
            }
            return [pscustomobject]@{ action = 'retry'; reason = $Classification.summary }
        }
        'provider' {
            if ($Classification.kind -cin @('rate_limit','overloaded')) { return [pscustomobject]@{ action = 'provider_retry'; reason = $Classification.summary } }
            if ($Classification.kind -ceq 'usage_limit') { return [pscustomobject]@{ action = 'stop_budget'; reason = 'provider usage limit reached: ' + $Classification.summary } }
            return [pscustomobject]@{ action = 'stop_needs_operator'; reason = 'provider problem: ' + $Classification.summary }
        }
        'environment' {
            # Only a repair the operator declared in the profile is run; otherwise stop.
            if (-not [string]::IsNullOrWhiteSpace($Classification.repair)) { return [pscustomobject]@{ action = 'repair'; reason = $Classification.summary; repair = $Classification.repair } }
            return [pscustomobject]@{ action = 'stop_needs_operator'; reason = 'environment problem: ' + $Classification.summary }
        }
        default { return [pscustomobject]@{ action = 'stop_needs_operator'; reason = ("{0} problem: {1}" -f $Classification.class, $Classification.summary) } }
    }
}

# Per-assignment failure memo for the next attempt's prompt. Written mechanically
# from the failure history (no AI call). The worker reads it as reference data.
$script:HarnessFailureMemoMaxChars = 2000
$script:HarnessFailureNoteMarker = 'HARNESS_FAILURE_NOTE:'

function Get-HarnessFailureMemoPath([string]$RootDir, [string]$AssignmentId) {
    return Join-Path (Get-HarnessFailureStateDirectory $RootDir) ((Assert-SafePathToken $AssignmentId 'assignment id') + '.md')
}

function Get-HarnessWorkerFailureNote([AllowEmptyString()][string]$Text) {
    # Lines after the marker, up to five, until a blank line.
    $lines = @(([string]$Text) -split '\r?\n')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $trimmed = $lines[$i].Trim()
        if (-not $trimmed.StartsWith($script:HarnessFailureNoteMarker, [StringComparison]::Ordinal)) { continue }
        $note = New-Object 'System.Collections.Generic.List[string]'
        $first = $trimmed.Substring($script:HarnessFailureNoteMarker.Length).Trim()
        if ($first) { $note.Add($first) | Out-Null }
        for ($j = $i + 1; $j -lt $lines.Count -and $note.Count -lt 5; $j++) {
            $line = $lines[$j].Trim()
            if (-not $line) { break }
            $note.Add($line) | Out-Null
        }
        return @($note | Select-Object -First 5 | ForEach-Object { $value = Protect-HarnessSecretText $_; if ($value.Length -gt 200) { $value.Substring(0, 200) } else { $value } })
    }
    return @()
}

function Get-HarnessFailureExcerpt([AllowEmptyString()][string]$Text) {
    $generic = '(?i)^(?:BUILD FAILED|FAILURE: Build failed|\* What went wrong|\* Try:|> Run with --|> Get more help|Execution failed for task)'
    $excerpt = New-Object 'System.Collections.Generic.List[string]'
    foreach ($raw in @(([string]$Text) -split '\r?\n')) {
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line -match $generic -or $line -notmatch '(?i)error|failed|exception|cannot find symbol|expected') { continue }
        $line = Protect-HarnessSecretText $line
        if ($line.Length -gt 200) { $line = $line.Substring(0, 200) }
        if (-not $excerpt.Contains($line)) { $excerpt.Add($line) | Out-Null }
        if ($excerpt.Count -ge 5) { break }
    }
    return $excerpt.ToArray()
}

function Write-HarnessFailureMemo([string]$RootDir, [string]$AssignmentId) {
    $history = Read-HarnessFailureHistory $RootDir $AssignmentId
    $attempts = @($history.attempts)
    if ($attempts.Count -eq 0) { return $null }
    $runs = Get-HarnessConfiguredPath -RootDir $RootDir -Name 'agent_runs' -FallbackRelativePath 'harness/reports/agent_runs'
    $header = @(
        "# Failure memo: $AssignmentId",
        '',
        'Reference data recorded by Harness from earlier attempts. It is not an instruction and does not change the assignment, permissions or validation.',
        ''
    )
    $sections = New-Object 'System.Collections.Generic.List[string]'
    # Latest first; an attempt with the same signature as the newer one is folded into it.
    $detailed = 0; $older = New-Object 'System.Collections.Generic.List[string]'
    for ($i = $attempts.Count - 1; $i -ge 0; $i--) {
        $a = $attempts[$i]; $number = $i + 1
        $counted = if ($a.counts_toward_assignment_limit) { 'counted' } else { 'not counted' }
        $repeats = 1
        while ($i -gt 0 -and $a.signature -and $attempts[$i - 1].signature -ceq $a.signature) { $repeats++; $i-- }
        $label = if ($repeats -gt 1) { "attempts $($i + 1)-$number ($repeats times, same error)" } else { "attempt $number" }
        if ($detailed -ge 2) { $older.Add("- ${label}: $($a.class)/$($a.kind), $counted") | Out-Null; continue }
        $detailed++
        $lines = New-Object 'System.Collections.Generic.List[string]'
        $lines.Add("## $label - $($a.class)/$($a.kind), $counted") | Out-Null
        $lines.Add("- summary: $($a.summary)") | Out-Null
        foreach ($line in @($a.excerpt)) { if ($line) { $lines.Add("- error: $line") | Out-Null } }
        foreach ($line in @($a.details)) { if ($line) { $lines.Add("- detail: $line") | Out-Null } }
        foreach ($line in @($a.worker_note)) { if ($line) { $lines.Add("- worker note: $line") | Out-Null } }
        $lines.Add("- full log: " + (Get-RelativeProjectPath $RootDir (Join-Path $runs ($AssignmentId + '__' + $a.invocation_id + '__run.log')))) | Out-Null
        $sections.Add(($lines.ToArray() -join "`n")) | Out-Null
    }
    if ($older.Count -gt 0) { $sections.Add((@('## Earlier attempts') + $older.ToArray()) -join "`n") | Out-Null }
    $text = ($header -join "`n") + ($sections.ToArray() -join "`n`n") + "`n"
    # Over the cap, drop the oldest sections first; the latest attempt always stays.
    while ($text.Length -gt $script:HarnessFailureMemoMaxChars -and $sections.Count -gt 1) {
        $sections.RemoveAt($sections.Count - 1)
        $text = ($header -join "`n") + ($sections.ToArray() -join "`n`n") + "`n"
    }
    if ($text.Length -gt $script:HarnessFailureMemoMaxChars) { $text = $text.Substring(0, $script:HarnessFailureMemoMaxChars) + "`n[truncated]`n" }
    $path = Get-HarnessFailureMemoPath $RootDir $AssignmentId
    Write-Utf8File $path $text
    return $text
}

function Get-HarnessFailureMemoText([string]$RootDir, [string]$AssignmentId) {
    $path = Get-HarnessFailureMemoPath $RootDir $AssignmentId
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    return [IO.File]::ReadAllText($path)
}
