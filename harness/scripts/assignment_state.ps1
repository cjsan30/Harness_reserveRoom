# Loaded by harness_common.ps1. Queue and invocation mutations require their leases.
function Assert-HarnessLeaseOwned {
    param($Lease, [string]$ExpectedPath)
    if ($Lease -isnot [PortableHarness.LockLease]) { throw 'an owned lease is required' }
    $key = [IO.Path]::GetFullPath($Lease.Path)
    if (-not [string]::Equals($key, [IO.Path]::GetFullPath($ExpectedPath), (Get-HarnessPathComparison)) -or
        -not $script:HarnessOwnedLocks.ContainsKey($key) -or
        $script:HarnessOwnedLocks[$key].Metadata.owner_id -cne $Lease.OwnerId) {
        throw 'lease does not own this operation'
    }
}

function Get-HarnessTextHash {
    param([AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($script:HarnessUtf8NoBom.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Enter-AssignmentQueue {
    param([string]$RootDir, [string]$Owner)
    $dirs = Get-AssignmentDirectories $RootDir $Owner
    $lease = Acquire-HarnessLock -LockRoot $dirs.Root -LockName '.queue'
    if ($null -eq $lease) { throw "assignment queue is busy: $Owner" }
    try { Repair-AssignmentTransitions -OwnerRoot $dirs.Root -QueueLease $lease }
    catch { Release-HarnessLock $lease; throw }
    return $lease
}

function Resolve-QueueJournalPath {
    param([string]$OwnerRoot, [string]$RelativePath)
    if ($RelativePath -cnotmatch '^(inbox|in_progress|done)/[^/\\]+\.md$') { throw 'invalid queue journal path' }
    return Resolve-ProjectPath $OwnerRoot $RelativePath -Label 'queue journal path'
}

function Invoke-QueueTransitionCheckpoint {
    param([string]$Stage)
    # In-process fault injection used only by isolated regression fixtures.
    if (Get-Variable HarnessTransitionCheckpoint -Scope Script -ErrorAction SilentlyContinue) {
        & $script:HarnessTransitionCheckpoint $Stage
    }
}

function Complete-AssignmentTransition {
    param([string]$OwnerRoot, [string]$JournalPath, $Record)
    if ($Record.version -ne 1 -or $Record.status -cne 'pending' -or
        $Record.id -cnotmatch '^[a-f0-9]{32}$' -or
        [IO.Path]::GetFileNameWithoutExtension($JournalPath) -cne $Record.id) { throw 'invalid queue journal record' }
    $source = Resolve-QueueJournalPath $OwnerRoot $Record.source
    $target = Resolve-QueueJournalPath $OwnerRoot $Record.target
    if ($source -eq $target -or $Record.source_hash -cnotmatch '^[a-f0-9]{64}$' -or
        (Get-HarnessTextHash $Record.content) -cne $Record.target_hash) { throw 'queue journal content is corrupt' }
    # Check both sides before changing either. Conflicting content is never overwritten.
    $sourceExists = Test-Path -LiteralPath $source
    $targetExists = Test-Path -LiteralPath $target
    if ($sourceExists -and (Get-HarnessTextHash ([IO.File]::ReadAllText($source))) -cne $Record.source_hash) { throw 'queue source changed during transition' }
    if ($targetExists -and (Get-HarnessTextHash ([IO.File]::ReadAllText($target))) -cne $Record.target_hash) { throw 'queue target conflicts with journal' }
    if (-not $sourceExists -and -not $targetExists) { throw 'both queue transition files are missing' }
    if (-not $targetExists) { Write-Utf8File $target $Record.content }
    Invoke-QueueTransitionCheckpoint 'target_written'
    if ($sourceExists) { Remove-Item -LiteralPath $source -Force -ErrorAction Stop }
    Invoke-QueueTransitionCheckpoint 'source_removed'
    $Record.status = 'committed'
    $Record | Add-Member -NotePropertyName committed_at -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    Write-Utf8File $JournalPath ($Record | ConvertTo-Json -Depth 8)
}

function Repair-AssignmentTransitions {
    param([string]$OwnerRoot, $QueueLease)
    Assert-HarnessLeaseOwned $QueueLease (Join-Path $OwnerRoot '.queue')
    $journalRoot = Join-Path $OwnerRoot '.transitions'
    if (-not (Test-Path -LiteralPath $journalRoot)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $journalRoot -Filter '*.json' -File | Sort-Object Name)) {
        $record = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
        if ($record.version -ne 1 -or $record.status -cnotin @('pending', 'committed')) { throw 'unsupported queue journal record' }
        if ($record.status -ceq 'pending') { Complete-AssignmentTransition $OwnerRoot $file.FullName $record }
    }
}

function Test-AssignmentQueueUnresolved {
    param([string]$RootDir, [string]$Owner)
    $dirs = Get-AssignmentDirectories $RootDir $Owner
    $journalRoot = Join-Path $dirs.Root '.transitions'
    if (-not (Test-Path -LiteralPath $journalRoot)) { return $false }
    foreach ($file in @(Get-ChildItem -LiteralPath $journalRoot -Filter '*.json' -File)) {
        try { $record = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json }
        catch { return $true }
        if ($record.version -ne 1 -or $record.status -cne 'committed') { return $true }
    }
    return $false
}

function Move-AssignmentWithJournal {
    param([string]$SourcePath, [string]$TargetPath, [string]$UpdatedContent, $QueueLease)
    $ownerRoot = Split-Path -Parent (Split-Path -Parent ([IO.Path]::GetFullPath($SourcePath)))
    Assert-HarnessLeaseOwned $QueueLease (Join-Path $ownerRoot '.queue')
    $sourceRelative = (Get-RelativeProjectPath $ownerRoot $SourcePath).Replace('\', '/')
    $targetRelative = (Get-RelativeProjectPath $ownerRoot $TargetPath).Replace('\', '/')
    $source = Resolve-QueueJournalPath $ownerRoot $sourceRelative
    $target = Resolve-QueueJournalPath $ownerRoot $targetRelative
    if (-not (Test-Path -LiteralPath $source)) { throw "source file not found: $source" }
    if (Test-Path -LiteralPath $target) { throw "target file already exists: $target" }
    $record = [pscustomobject]@{
        version=1; id=[Guid]::NewGuid().ToString('N'); status='pending'
        source=$sourceRelative; target=$targetRelative
        source_hash=(Get-HarnessTextHash ([IO.File]::ReadAllText($source)))
        target_hash=(Get-HarnessTextHash $UpdatedContent); content=$UpdatedContent
        created_at=[DateTime]::UtcNow.ToString('o')
    }
    $journalPath = Join-Path (Join-Path $ownerRoot '.transitions') ($record.id + '.json')
    Write-Utf8File $journalPath ($record | ConvertTo-Json -Depth 8)
    Invoke-QueueTransitionCheckpoint 'intent_written'
    Complete-AssignmentTransition $ownerRoot $journalPath $record
}

function Get-HarnessLinuxProcessIdentity([int]$ProcessId) {
    if((Test-HarnessIsWindows) -or $ProcessId -le 0){return $null}
    try {
        # Kernel boot ID + monotonic process start ticks are stable across wall
        # clock corrections; .NET Linux StartTime is a wall clock conversion.
        $boot=[IO.File]::ReadAllText('/proc/sys/kernel/random/boot_id').Trim()
        $stat=[IO.File]::ReadAllText('/proc/'+$ProcessId+'/stat')
        $close=$stat.LastIndexOf(')')
        if($boot -cnotmatch '^[a-f0-9-]{36}$' -or $close -lt 0){return $null}
        $fields=$stat.Substring($close+1).Trim() -split '\s+'
        if($fields.Count -lt 20 -or $fields[19] -cnotmatch '^[0-9]+$'){return $null}
        return 'linux:'+$boot+':'+$ProcessId+':'+$fields[19]
    } catch { return $null }
}

function Get-AssignmentWorkerPaths {
    param([string]$RootDir, [string]$AssignmentId)
    $id = Assert-SafePathToken $AssignmentId 'assignment id'
    $lockRoot = Get-HarnessLockRoot $RootDir
    return @{
        Record = Join-Path (Join-Path $lockRoot ('invoke_' + $id)) 'worker.json'
        Lease = Join-Path $lockRoot ('worker_' + $id)
        LockRoot = $lockRoot
    }
}

function Get-AssignmentWorkerRecord {
    param([string]$RootDir, [string]$AssignmentId)
    $paths = Get-AssignmentWorkerPaths $RootDir $AssignmentId
    if (-not (Test-Path -LiteralPath $paths.Record)) { return $null }
    $record = [IO.File]::ReadAllText($paths.Record) | ConvertFrom-Json
    if ($record.version -ne 1 -or $record.assignment_id -cne $AssignmentId -or
        $record.invocation_id -cnotmatch '^[a-f0-9]{32}$' -or
        -not [string]::Equals([IO.Path]::GetFullPath($RootDir), $record.root, (Get-HarnessPathComparison)) -or
        $record.status -cnotin @('starting', 'running', 'exited', 'settled')) { throw 'invalid worker record; manual inspection required' }
    if($null -ne $record.PSObject.Properties['provider_contract']){Assert-HarnessProviderContract $record.provider_contract}
    return $record
}

function Test-AssignmentWorkerUnsettled {
    param([string]$RootDir, [string]$AssignmentId)
    $paths = Get-AssignmentWorkerPaths $RootDir $AssignmentId
    if (Test-HarnessLockActive $paths.Lease) { return $true }
    $record = Get-AssignmentWorkerRecord $RootDir $AssignmentId
    return ($null -ne $record -and $record.status -cne 'settled')
}

function New-AssignmentWorkerIntent {
    param([string]$RootDir, [string]$Owner, [string]$AssignmentId, $InvokeLease,
        [string]$Executable, [string[]]$Arguments, [string]$PromptFile, [string]$LogFile, [string]$ExecutionRoot, $ProviderContract=$null)
    Assert-HarnessLeaseOwned $InvokeLease (Get-AssignmentInvokeLockPath $RootDir $AssignmentId)
    if (Test-AssignmentWorkerUnsettled $RootDir $AssignmentId) { throw 'previous worker execution is unresolved; refusing duplicate launch' }
    if($null -eq $ProviderContract){$ProviderContract=Get-HarnessWorkerProviderContract ([pscustomobject]@{arguments=@($Arguments)})}
    Assert-HarnessProviderContract $ProviderContract
    $record = [pscustomobject]@{
        version=1; invocation_id=[Guid]::NewGuid().ToString('N'); assignment_id=$AssignmentId
        owner=$Owner; root=[IO.Path]::GetFullPath($RootDir); status='starting'
        parent_pid=$PID; parent_started_at=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
        host=[Environment]::MachineName; created_at=[DateTime]::UtcNow.ToString('o')
        executable=$Executable; arguments=@($Arguments); prompt_file=$PromptFile; log_file=$LogFile; execution_root=$ExecutionRoot
        worker_pid=$null; worker_started_at=$null; exit_code=$null
        provider_contract=$ProviderContract; provider_result=$null
        # Bound into the durable intent so the worker host does not re-read a changed profile.
        timeout_seconds=(Get-HarnessExecutionPolicy $RootDir).max_invocation_seconds; timed_out=$false
    }
    # Reserve before spawn/intent publication. An interrupted reservation remains
    # charged; it is never silently refunded on an unconfirmed process exit.
    New-HarnessUsageReservation $RootDir $record
    Write-Utf8File (Get-AssignmentWorkerPaths $RootDir $AssignmentId).Record ($record | ConvertTo-Json -Depth 8)
    return $record
}

function Set-AssignmentWorkerSettled {
    param([string]$RootDir, [string]$AssignmentId, [string]$InvocationId, $InvokeLease)
    Assert-HarnessLeaseOwned $InvokeLease (Get-AssignmentInvokeLockPath $RootDir $AssignmentId)
    $paths = Get-AssignmentWorkerPaths $RootDir $AssignmentId
    if (Test-HarnessLockActive $paths.Lease) { throw 'worker is still active' }
    $record = Get-AssignmentWorkerRecord $RootDir $AssignmentId
    if ($null -eq $record -or $record.invocation_id -cne $InvocationId -or $record.status -cne 'exited') { throw 'worker exit has not been confirmed' }
    $record.status = 'settled'
    Write-Utf8File $paths.Record ($record | ConvertTo-Json -Depth 8)
}

function Repair-AssignmentWorkerExit {
    param([string]$RootDir, [string]$Owner, [string]$AssignmentId)
    $invokePath = Get-AssignmentInvokeLockPath $RootDir $AssignmentId
    $invokeLease = Acquire-HarnessLock (Split-Path -Parent $invokePath) (Split-Path -Leaf $invokePath)
    if ($null -eq $invokeLease) { throw 'invocation is active; reconciliation refused' }
    try {
        $paths = Get-AssignmentWorkerPaths $RootDir $AssignmentId
        $record = Get-AssignmentWorkerRecord $RootDir $AssignmentId
        if ($null -eq $record -or $record.status -ceq 'settled') { return }
        if ($record.owner -cne $Owner) { throw 'worker owner mismatch' }
        if ((Test-HarnessLockActive $paths.Lease) -or $record.status -cne 'exited') {
            throw 'worker exit is unconfirmed; inspect processes and worktree manually; no process was killed or requeued'
        }
        $queueLease = Enter-AssignmentQueue $RootDir $Owner
        try {
            $dirs = Get-AssignmentDirectories $RootDir $Owner
            $progress = Join-Path $dirs.InProgress ($AssignmentId + '.md')
            $done = @(Get-ChildItem -LiteralPath $dirs.Done -Filter '*.md' -File | Where-Object { $_.BaseName -cin @(($AssignmentId + '__pass'), ($AssignmentId + '__fail')) })
            if ($done.Count -gt 1 -or ($done.Count -eq 1 -and (Test-Path -LiteralPath $progress))) { throw 'conflicting completion files require inspection' }
            if($done.Count -eq 1 -and $done[0].BaseName -ceq ($AssignmentId+'__pass')){
                Assert-AssignmentCompletionEvidence $RootDir $Owner $AssignmentId ([IO.File]::ReadAllText($done[0].FullName)) | Out-Null
            }
            if ($done.Count -eq 0) {
                if (-not (Test-Path -LiteralPath $progress)) { throw 'no assignment exists to reconcile worker exit' }
                $text = [IO.File]::ReadAllText($progress) -replace '- status: in_progress', '- status: done'
                $text = $text -replace '- result: pending', '- result: fail'
                $text += "`n`n## Recovery`n`n- reason: worker exited without confirmed assignment completion; validation was not inferred from exit code`n"
                Move-FileWithUpdatedContent $progress (Join-Path $dirs.Done ($AssignmentId + '__fail.md')) $text $queueLease
            }
            Set-AssignmentWorkerSettled $RootDir $AssignmentId $record.invocation_id $invokeLease
        } finally { Release-HarnessLock $queueLease }
    } finally { Release-HarnessLock $invokeLease }
}
