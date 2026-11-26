# Local accounting for launches made by this Harness. This is not a provider
# billing ledger or an account quota reader. The only in-flight control is the
# per-invocation wall-clock limit (max_invocation_seconds) enforced by the worker host.
function Test-HarnessUsageInteger($Value) {
    return ($null -ne $Value -and ($Value -is [int] -or $Value -is [long]) -and $Value -ge 0)
}

function Get-HarnessExecutionPolicy([string]$RootDir) {
    # Read fresh while holding the accounting lock: profile caching must not hide
    # a newly tightened policy in a long-lived dispatch process.
    $profile = [IO.File]::ReadAllText((Get-ProjectProfilePath $RootDir)) | ConvertFrom-Json
    $policy = [ordered]@{ billing_mode='unknown'; max_invocations=$null; max_attempts_per_assignment=$null; max_concurrent_workers=$null; max_total_tokens=$null; max_total_duration_seconds=$null; max_invocation_seconds=$null }
    if ($null -ne $profile.execution_policy) {
        foreach ($property in $profile.execution_policy.PSObject.Properties) {
            if (-not $policy.Contains($property.Name)) { throw "unknown execution policy field: $($property.Name)" }
            $policy[$property.Name] = $property.Value
        }
    }
    if ($policy.billing_mode -cnotin @('unknown','subscription','api')) { throw 'invalid execution policy billing_mode' }
    foreach ($name in @('max_invocations','max_attempts_per_assignment','max_concurrent_workers','max_total_tokens','max_total_duration_seconds')) {
        if ($null -ne $policy[$name] -and -not (Test-HarnessUsageInteger $policy[$name])) { throw "execution policy $name must be null or a nonnegative integer" }
    }
    # A running worker is stopped after this many seconds; 0 would kill every run, so it is refused.
    if ($null -ne $policy.max_invocation_seconds -and (-not (Test-HarnessUsageInteger $policy.max_invocation_seconds) -or $policy.max_invocation_seconds -lt 1)) { throw 'execution policy max_invocation_seconds must be null or a positive integer' }
    return [pscustomobject]$policy
}

function Get-HarnessUsageDirectory([string]$RootDir) {
    return Resolve-HarnessEnginePath $RootDir 'harness/state/usage' 'usage ledger'
}


function Read-HarnessUsageRecords([string]$RootDir) {
    $directory=Get-HarnessUsageDirectory $RootDir
    if (-not (Test-Path -LiteralPath $directory)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File)) {
        try { $record=[IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json } catch { throw 'invalid usage ledger JSON; execution refused' }
        if ($record.version -ne 1 -or $record.invocation_id -cnotmatch '^[a-f0-9]{32}$' -or $record.invocation_id -cne $file.BaseName -or
            -not [string]::Equals([IO.Path]::GetFullPath($RootDir), $record.root, (Get-HarnessPathComparison)) -or
            [string]::IsNullOrWhiteSpace($record.assignment_id) -or $record.status -cnotin @('reserved','completed') -or
            $record.billing_mode -cnotin @('unknown','subscription','api')) { throw 'invalid usage ledger record; execution refused' }
        Assert-HarnessProviderContract ([pscustomobject]@{version=1;provider=$record.provider;requested_model=$record.requested_model})
        if($null -ne $record.PSObject.Properties['provider_contract']){
            Assert-HarnessProviderContract $record.provider_contract
            if($record.provider -cne $record.provider_contract.provider -or $record.requested_model -cne $record.provider_contract.requested_model){throw 'usage provider identity mismatch'}
            if($record.status -ceq 'completed'){
                Assert-HarnessProviderResult $record.provider_result $record.provider_contract $record.invocation_id $record.exit_code
                if(($record.usage|ConvertTo-Json -Compress) -cne ($record.provider_result.usage|ConvertTo-Json -Compress)){throw 'usage and provider result disagree'}
            }
        }
        if ($record.status -ceq 'completed') {
            if ($null -eq $record.duration_seconds -or $record.duration_seconds -is [string] -or $record.duration_seconds -is [bool] -or
                [double]::IsNaN([double]$record.duration_seconds) -or [double]::IsInfinity([double]$record.duration_seconds) -or $record.duration_seconds -lt 0 -or
                $record.usage.status -cnotin @('known','unknown')) { throw 'invalid completed usage record' }
            if ($record.usage.status -ceq 'known') {
                foreach($name in @('input_tokens','cached_input_tokens','output_tokens')) {
                    if (-not (Test-HarnessUsageInteger $record.usage.$name)) { throw 'invalid token count in usage ledger' }
                }
                if ($record.usage.cached_input_tokens -gt $record.usage.input_tokens) { throw 'invalid cached token count' }
            }
        }
        $record
    }
}

function Get-HarnessUsageTotals($Records) {
    [decimal]$tokens=0; [double]$seconds=0; $unknown=0; $reserved=0
    # Tokens a provider reported for failed invocations. Informational only: the
    # invocation still counts as unknown and token budgets do not use this number.
    [decimal]$reportedTokens=0; $reportedCount=0
    foreach($record in @($Records)) {
        if ($record.status -ceq 'reserved') { $reserved++; $unknown++; continue }
        $seconds += $record.duration_seconds
        if ($record.usage.status -ceq 'known') { $tokens += [decimal]$record.usage.input_tokens + [decimal]$record.usage.output_tokens }
        else {
            $unknown++
            $result = $record.PSObject.Properties['provider_result']
            if ($null -ne $result -and $null -ne $result.Value -and $null -ne $result.Value.PSObject.Properties['reported_usage'] -and $null -ne $result.Value.reported_usage) {
                $reportedTokens += [decimal]$result.Value.reported_usage.input_tokens + [decimal]$result.Value.reported_usage.output_tokens
                $reportedCount++
            }
        }
    }
    return [pscustomobject]@{ invocation_count=@($Records).Count; reserved_count=$reserved; unknown_usage_count=$unknown; known_total_tokens=$tokens; completed_duration_seconds=$seconds; reported_failure_count=$reportedCount; reported_failure_tokens=$reportedTokens }
}

function New-HarnessUsageReservation([string]$RootDir, $WorkerRecord) {
    if ($WorkerRecord.invocation_id -cnotmatch '^[a-f0-9]{32}$') { throw 'invalid usage invocation ID' }
    $contract=Get-HarnessWorkerProviderContract $WorkerRecord
    $lease=Acquire-HarnessLock (Get-HarnessLockRoot $RootDir) 'execution_budget'
    if ($null -eq $lease) { throw 'execution accounting is busy; no worker launched' }
    try {
        $policy=Get-HarnessExecutionPolicy $RootDir
        $records=@(Read-HarnessUsageRecords $RootDir)
        $totals=Get-HarnessUsageTotals $records
        $attempts=@($records | Where-Object { $_.assignment_id -ceq $WorkerRecord.assignment_id -and $_.owner -ceq $WorkerRecord.owner }).Count
        if (@($records | Where-Object { $_.invocation_id -ceq $WorkerRecord.invocation_id }).Count) { throw 'duplicate usage reservation' }
        # Messages start with 'execution budget reached:' so the dispatcher can report the
        # limit instead of treating the refusal as a worker failure.
        if ($null -ne $policy.max_invocations -and $totals.invocation_count -ge $policy.max_invocations) { throw ("execution budget reached: max_invocations ({0} of {1} invocations used)" -f $totals.invocation_count, $policy.max_invocations) }
        if ($null -ne $policy.max_attempts_per_assignment) {
            # Only implementation failures count here; environment, permission, provider and
            # missing-information stops do not use up an assignment's attempts.
            $attemptStatus=Get-HarnessAssignmentAttemptStatus $RootDir $WorkerRecord.assignment_id $records $policy
            if ($attemptStatus.counted -ge $attemptStatus.limit) {
                throw ("execution budget reached: max_attempts_per_assignment ({0} of {1} counted attempts used for {2}; grant more with: harness.ps1 attempts -AssignmentId {2} -Grant 1 -Reason <text>)" -f $attemptStatus.counted, $attemptStatus.limit, $WorkerRecord.assignment_id)
            }
        }
        if ($null -ne $policy.max_concurrent_workers -and $totals.reserved_count -ge $policy.max_concurrent_workers) { throw ("execution budget reached: max_concurrent_workers ({0} of {1} running)" -f $totals.reserved_count, $policy.max_concurrent_workers) }
        if ($null -ne $policy.max_total_tokens) {
            if ($totals.unknown_usage_count -gt 0) { throw 'execution budget reached: max_total_tokens cannot be evaluated while usage is unknown or reserved' }
            if ($totals.known_total_tokens -ge $policy.max_total_tokens) { throw ("execution budget reached: max_total_tokens ({0} of {1} tokens used)" -f $totals.known_total_tokens, $policy.max_total_tokens) }
        }
        if ($null -ne $policy.max_total_duration_seconds) {
            if ($totals.reserved_count -gt 0) { throw 'execution budget reached: max_total_duration_seconds cannot be evaluated while an invocation is unresolved' }
            if ($totals.completed_duration_seconds -ge $policy.max_total_duration_seconds) { throw ("execution budget reached: max_total_duration_seconds ({0:N0} of {1} seconds used)" -f $totals.completed_duration_seconds, $policy.max_total_duration_seconds) }
        }
        $record=[pscustomobject]@{
            version=1; root=[IO.Path]::GetFullPath($RootDir); invocation_id=$WorkerRecord.invocation_id
            assignment_id=$WorkerRecord.assignment_id; owner=$WorkerRecord.owner; attempt=($attempts+1)
            provider=$contract.provider; provider_contract=$contract; provider_result=$null
            requested_model=$contract.requested_model; resolved_model=$null; billing_mode=$policy.billing_mode
            status='reserved'; reserved_at=[DateTime]::UtcNow.ToString('o'); completed_at=$null
            duration_seconds=$null; exit_code=$null; usage=$null; actual_cost_usd=$null
        }
        Write-Utf8File (Join-Path (Get-HarnessUsageDirectory $RootDir) ($record.invocation_id+'.json')) ($record | ConvertTo-Json -Depth 8)
    } finally { Release-HarnessLock $lease }
}

function Complete-HarnessUsageReservation([string]$RootDir, $WorkerRecord, [string]$LogPath, [int]$ExitCode, [double]$DurationSeconds, $ProviderResult=$null) {
    if ([double]::IsNaN($DurationSeconds) -or [double]::IsInfinity($DurationSeconds) -or $DurationSeconds -lt 0) { throw 'invalid worker duration' }
    $contract=Get-HarnessWorkerProviderContract $WorkerRecord
    if($null -eq $ProviderResult){$ProviderResult=Get-HarnessProviderResult $WorkerRecord $LogPath $ExitCode}
    Assert-HarnessProviderResult $ProviderResult $contract $WorkerRecord.invocation_id $ExitCode
    $usage=$ProviderResult.usage
    $lease=Acquire-HarnessLock (Get-HarnessLockRoot $RootDir) 'execution_budget'
    if ($null -eq $lease) { throw 'execution accounting is busy; worker remains quarantined' }
    try {
        $matches=@(Read-HarnessUsageRecords $RootDir | Where-Object { $_.invocation_id -ceq $WorkerRecord.invocation_id })
        if ($matches.Count -ne 1) { throw 'usage reservation missing' }
        $record=$matches[0]
        if($record.assignment_id -cne $WorkerRecord.assignment_id -or $record.owner -cne $WorkerRecord.owner) { throw 'usage reservation identity mismatch' }
        if($record.provider -cne $contract.provider -or $record.requested_model -cne $contract.requested_model){throw 'usage reservation provider mismatch'}
        if($record.status -cne 'reserved') { throw 'usage reservation is already completed' }
        $record.status='completed'; $record.completed_at=[DateTime]::UtcNow.ToString('o')
        $record.duration_seconds=$DurationSeconds; $record.exit_code=$ExitCode; $record.usage=$usage
        $record|Add-Member -NotePropertyName provider_contract -NotePropertyValue $contract -Force
        $record|Add-Member -NotePropertyName provider_result -NotePropertyValue $ProviderResult -Force
        Write-Utf8File (Join-Path (Get-HarnessUsageDirectory $RootDir) ($record.invocation_id+'.json')) ($record | ConvertTo-Json -Depth 8)
    } finally { Release-HarnessLock $lease }
}
