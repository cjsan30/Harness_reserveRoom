param(
    [Parameter(Mandatory = $true)]
    [string]$Agent,
    [Parameter(Mandatory = $true)]
    [ValidateSet("pass", "fail")]
    [string]$Result,
    [string]$AssignmentId,
    [switch]$Revalidate
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
if($Revalidate -and $Result -ne 'pass'){throw '-Revalidate requires -Result pass'}

$rootDir = Get-HarnessRoot -ScriptDirectory $PSScriptRoot
$assignmentLog = Get-HarnessConfiguredPath -RootDir $rootDir -Name "assignment_log" -FallbackRelativePath "harness/reports/assignment_log.md"
$lockRoot = Get-HarnessLockRoot -RootDir $rootDir
$ownerDirs = Get-AssignmentDirectories -RootDir $rootDir -Owner $Agent

if (-not (Test-Path -LiteralPath $assignmentLog)) {
    Write-Utf8File -Path $assignmentLog -Content "# Assignment Log`n`n## Entries`n"
}

$completeLock = Enter-AssignmentQueue $rootDir $Agent
if ($null -eq $completeLock) {
    throw "complete lock is already held for $Agent"
}

try {
    $progressItems = Get-ChildItem -LiteralPath $ownerDirs.InProgress -File | Sort-Object LastWriteTime

    if ([string]::IsNullOrWhiteSpace($AssignmentId)) {
        if ($progressItems.Count -gt 1) {
            throw "multiple assignments are in progress for $Agent; specify -AssignmentId"
        }
        $currentItem = $progressItems | Select-Object -First 1
    } else {
        $currentItem = $progressItems | Where-Object { $_.BaseName -eq $AssignmentId } | Select-Object -First 1
    }

    if ($null -eq $currentItem) {
        if (-not [string]::IsNullOrWhiteSpace($AssignmentId)) {
            $existing = @(Get-ChildItem -LiteralPath $ownerDirs.Done -File | Where-Object { $_.BaseName -ceq ($AssignmentId + '__' + $Result) })
            if ($existing.Count -eq 1) {
                if($Result -eq 'pass'){
                    if($Revalidate){
                        $worker=Get-AssignmentWorkerRecord $rootDir $AssignmentId
                        if($null -ne $worker -and ($worker.status -cnotin @('exited','settled') -or $null -eq $worker.exit_code -or $worker.exit_code -ne 0)) {throw 'revalidation requires a confirmed successful worker exit or a manual assignment'}
                        if($null -ne $worker){Assert-HarnessWorkerProviderSuccess $worker}
                        $original=[IO.File]::ReadAllText($existing[0].FullName)
                        $updated=($original -split '\r?\n' | Where-Object {$_ -notmatch '^\s*- validation_evidence:'}) -join "`n"
                        $evidence=New-AssignmentValidationEvidence $rootDir $Agent $AssignmentId $updated
                        if([IO.File]::ReadAllText($existing[0].FullName) -cne $original){throw 'completed assignment changed during revalidation'}
                        $updated += "`n- validation_evidence: $($evidence.id)`n"
                        $evidence.completed_assignment_hash=Get-HarnessTextHash $updated
                        Write-Utf8File (Join-Path (Get-AssignmentEvidenceDirectory $rootDir) ($evidence.id+'.json')) ($evidence|ConvertTo-Json -Depth 10)
                        Write-Utf8File $existing[0].FullName $updated
                    }
                    Assert-AssignmentCompletionEvidence $rootDir $Agent $AssignmentId ([IO.File]::ReadAllText($existing[0].FullName)) -AllowActiveWorker | Out-Null
                }
                Write-Output "assignment already completed: $($existing[0].FullName)"; exit 0
            }
            throw "no matching assignment in progress for $Agent with assignment_id: $AssignmentId"
        }
        Write-Output "no matching assignment in progress for $Agent"
        exit 0
    }

    $doneContent = Get-Content -Raw -Encoding UTF8 -LiteralPath $currentItem.FullName
    $originalContent = $doneContent
    $doneContent = $doneContent -replace "- status: in_progress", "- status: done"
    $doneContent = $doneContent -replace "- result: pending", "- result: $Result"
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($currentItem.Name)
    $extension = [System.IO.Path]::GetExtension($currentItem.Name)
    $targetName = $baseName + "__" + $Result + $extension
    $targetPath = Join-Path $ownerDirs.Done $targetName

    $workerRecord = Get-AssignmentWorkerRecord $rootDir $baseName
    if ($null -ne $workerRecord -and $workerRecord.status -cin @('starting', 'running')) {
        if ($env:HARNESS_INVOCATION_ID -cne $workerRecord.invocation_id -or $env:HARNESS_ASSIGNMENT_ID -cne $baseName) {
            throw 'only the current worker may complete an active invocation'
        }
    }
    if($Result -eq 'pass') {
        if($null -ne $workerRecord -and $workerRecord.status -cin @('exited','settled') -and ($null -eq $workerRecord.exit_code -or $workerRecord.exit_code -ne 0)){throw 'worker did not exit successfully; pass refused'}
        $evidence=New-AssignmentValidationEvidence $rootDir $Agent $baseName $originalContent
        if([IO.File]::ReadAllText($currentItem.FullName) -cne $originalContent){throw 'assignment changed during validation; completion refused'}
        $doneContent += "`n- validation_evidence: $($evidence.id)`n"
        $evidence.completed_assignment_hash=Get-HarnessTextHash $doneContent
        Write-Utf8File (Join-Path (Get-AssignmentEvidenceDirectory $rootDir) ($evidence.id+'.json')) ($evidence|ConvertTo-Json -Depth 10)
        Assert-AssignmentCompletionEvidence $rootDir $Agent $baseName $doneContent -AllowActiveWorker | Out-Null
    }
    Move-FileWithUpdatedContent -SourcePath $currentItem.FullName -TargetPath $targetPath -UpdatedContent $doneContent -QueueLease $completeLock

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = @"
- time: $timestamp
  - action: complete
  - owner: $Agent
  - result: $Result
  - assignment_id: $baseName
  - assignment: $targetName
"@
    Append-Utf8File -Path $assignmentLog -Content $entry
    Write-Output "completed assignment: $targetPath"
} finally {
    Release-HarnessLock -LockPath $completeLock
}
