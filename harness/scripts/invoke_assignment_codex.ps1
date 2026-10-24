param(
    [Parameter(Mandatory = $true)]
    [string]$Agent,
    [Parameter(Mandatory = $true)]
    [string]$AssignmentId,
    [switch]$Ephemeral,
    [string]$Model,
    [switch]$DryRun,
    [switch]$PreflightOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
. (Join-Path $PSScriptRoot "git_workflow_common.ps1")

$rootDir = Get-HarnessRoot -ScriptDirectory $PSScriptRoot
$provider=Get-HarnessConfiguredProvider $rootDir
$runsDir = Get-HarnessConfiguredPath -RootDir $rootDir -Name "agent_runs" -FallbackRelativePath "harness/reports/agent_runs"
$lockRoot = Get-HarnessLockRoot -RootDir $rootDir
$dispatchPackets = Get-HarnessConfiguredPath -RootDir $rootDir -Name "dispatch_packets" -FallbackRelativePath "harness/reports/dispatch_packets"
$assignmentLog = Get-HarnessConfiguredPath -RootDir $rootDir -Name "assignment_log" -FallbackRelativePath "harness/reports/assignment_log.md"
$liveDispatchLog = Get-HarnessConfiguredPath -RootDir $rootDir -Name "live_dispatch_log" -FallbackRelativePath "harness/reports/live_dispatch_log.md"
$providerLaunch=New-HarnessProviderLaunch $provider $rootDir (Join-Path $runsDir ($AssignmentId+'__last_message.txt')) $Model -Ephemeral:$Ephemeral
$executionRoot = $rootDir
$launchIntentFailed = $false

Ensure-HarnessDirectory -Path $runsDir
if (-not (Test-Path -LiteralPath $liveDispatchLog)) {
    Write-Utf8File -Path $liveDispatchLog -Content "# Live Dispatch Log`n`n## Entries`n"
}
$ownerDirs = Get-AssignmentDirectories -RootDir $rootDir -Owner $Agent
$invokeLock = Acquire-HarnessLock -LockRoot $lockRoot -LockName ("invoke_" + $AssignmentId) -MaxAgeSeconds 7200
if ($null -eq $invokeLock) {
    throw "invoke lock is already held for assignment $AssignmentId"
}

function Get-AssignmentFilePath {
    param(
        [string]$BaseDir,
        [string]$Id
    )

    $file = Get-ChildItem -LiteralPath $BaseDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -eq $Id } |
        Select-Object -First 1
    if ($null -eq $file) {
        return $null
    }

    return $file.FullName
}

try {
    if (Test-AssignmentWorkerUnsettled $rootDir $AssignmentId) { throw 'previous worker execution requires reconciliation; refusing duplicate launch' }
    $queueLease = Enter-AssignmentQueue $rootDir $Agent
    Release-HarnessLock $queueLease
    $inboxPath = Get-AssignmentFilePath -BaseDir $ownerDirs.Inbox -Id $AssignmentId
    $progressPath = Get-AssignmentFilePath -BaseDir $ownerDirs.InProgress -Id $AssignmentId
    if ($null -eq $inboxPath -and $null -eq $progressPath) {
        $doneMatch = Get-ChildItem -LiteralPath $ownerDirs.Done -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -like ($AssignmentId + "__*") } |
            Select-Object -First 1
        if ($null -ne $doneMatch) {
            if($doneMatch.BaseName -ceq ($AssignmentId+'__pass')){Assert-AssignmentCompletionEvidence $rootDir $Agent $AssignmentId ([IO.File]::ReadAllText($doneMatch.FullName)) | Out-Null}
            Write-Output "assignment already completed: $($doneMatch.FullName)"
            exit 0
        }

        throw "assignment not found in inbox or in_progress: $AssignmentId"
    }

    $assignmentPath = $progressPath
    if ($null -eq $assignmentPath) {
        $assignmentPath = $inboxPath
    }

    $assignmentContent = Get-Content -Encoding UTF8 -LiteralPath $assignmentPath
    $featureBranch = Get-MarkdownValue -Content $assignmentContent -Key "feature_branch"
    if ([string]::IsNullOrWhiteSpace($featureBranch)) {
        $featureBranch = Get-GitExpectedAssignmentBranch -RootDir $rootDir -Owner $Agent -AssignmentId $AssignmentId
    }
    $branchBefore = Get-GitCurrentBranch -RootDir $rootDir
    $branchAfter = $branchBefore
    $branchAction = "none"
    $branchStatus = "unchanged"
    $branchBase = ""
    $workspaceAction = "none"
    $workspaceStatus = "shared_workspace"
    $worktreePath = Get-GitAssignmentWorktreePath -RootDir $rootDir -Owner $Agent -AssignmentId $AssignmentId

    if ($DryRun -or $PreflightOnly) {
        try {
            $branchBase = Get-GitAssignmentBaseBranch -RootDir $rootDir
            $branchStatus = "live_execution_will_use_isolated_worktree"
        } catch {
            $branchBase = ""
            $branchStatus = "live_execution_requires_base_branch"
        }
        $workspaceAction = "plan_only"
        $workspaceStatus = "isolated_worktree_will_be_used"
    } else {
        $worktreeContext = Ensure-GitAssignmentWorktree -RootDir $rootDir -Owner $Agent -AssignmentId $AssignmentId
        $executionRoot = $worktreeContext.WorktreePath
        $worktreePath = $worktreeContext.WorktreePath
        $branchBase = $worktreeContext.BaseBranch
        $workspaceAction = $(if ($worktreeContext.CreatedWorktree) { "created_worktree" } else { "reused_worktree" })
        $workspaceStatus = "isolated_worktree_ready"
        $previousGitWorkspace = [Environment]::GetEnvironmentVariable("CODEX_GIT_WORKSPACE_ROOT")
        try {
            [Environment]::SetEnvironmentVariable("CODEX_GIT_WORKSPACE_ROOT", $executionRoot)
            $branchAfter = Get-GitCurrentBranch -RootDir $rootDir
        } finally {
            [Environment]::SetEnvironmentVariable("CODEX_GIT_WORKSPACE_ROOT", $previousGitWorkspace)
        }
        $branchAction = $(if ($worktreeContext.CreatedBranch) { "created_branch_in_worktree" } else { "reused_branch_in_worktree" })
        $branchStatus = "ready_in_isolated_worktree"
    }

    if (-not $DryRun -and -not $PreflightOnly -and $null -ne $inboxPath) {
        $claimResult = Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot "claim_assignment.ps1") -Arguments @("-Agent", $Agent, "-AssignmentId", $AssignmentId) -AllowFailure
        if (-not $claimResult.Success) {
            throw "failed to claim assignment $AssignmentId"
        }

        $progressPath = Get-AssignmentFilePath -BaseDir $ownerDirs.InProgress -Id $AssignmentId
        if ($null -eq $progressPath) {
            throw "assignment was claimed but is not present in in_progress: $AssignmentId"
        }
    }

    $assignmentPath = $progressPath
    if ($null -eq $assignmentPath) {
        $assignmentPath = $inboxPath
    }

    $assignmentContent = Get-Content -Encoding UTF8 -LiteralPath $assignmentPath
    $workArea = Get-MarkdownValue -Content $assignmentContent -Key "work_area"
    $validation = Get-MarkdownValue -Content $assignmentContent -Key "validation"
    $task = Get-MarkdownValue -Content $assignmentContent -Key "task"
    $packetFile = Join-Path $dispatchPackets ($AssignmentId + ".md")
    $promptFile = Join-Path $runsDir ($AssignmentId + "__prompt.md")
    $lastMessageFile = Join-Path $runsDir ($AssignmentId + "__last_message.txt")
    $runLogFile = Join-Path $runsDir ($AssignmentId + "__run.log")
    $summaryFile = Join-Path $runsDir ($AssignmentId + "__summary.md")

    if (-not (Test-Path -LiteralPath $packetFile)) {
        throw "dispatch packet not found: $packetFile"
    }
    $packetText = Get-Content -Raw -Encoding UTF8 -LiteralPath $packetFile

    if ([string]::IsNullOrWhiteSpace($workArea)) {
        $workArea = "project-wide"
    }

    $completionScript = Get-RelativeProjectPath $rootDir (Join-Path (Get-HarnessEngineRoot $rootDir) 'scripts/complete_assignment.ps1')
    $policyPath = Get-RelativeProjectPath $rootDir (Join-Path (Get-HarnessEngineRoot $rootDir) 'configs/git_policy.md')
    $prompt = @"
You are the assigned owner worker for assignment `$AssignmentId`.

Read and follow the assignment packet below.

$packetText

Execution rules:
- The assignment has already been claimed and is currently in progress.
- Work primarily in: $workArea
- Execute from isolated worktree: $executionRoot
- Required feature branch: $featureBranch
- Required validation: $validation
- Required task: $task
- You are not alone in the codebase. Do not revert edits you did not make.
- If you create a commit or push, follow $policyPath.
- If validation is expressed as multiple commands joined with `&&`, run the shell-appropriate sequential equivalent in the current environment.
- Before finishing, request success with the command below. Harness will execute the assignment validation command itself, record code and log evidence, and refuse success if it fails or changes source files. Do not edit source after this command:
  pwsh -NoProfile -File $completionScript -Agent $Agent -AssignmentId $AssignmentId -Result pass
- If you are blocked or validation fails, run:
  pwsh -NoProfile -File $completionScript -Agent $Agent -AssignmentId $AssignmentId -Result fail
- In your final message, briefly summarize changed files, validation run, and remaining risks.
"@
    Write-Utf8File -Path $promptFile -Content $prompt

    $providerLaunch=New-HarnessProviderLaunch $provider $executionRoot $lastMessageFile $Model -Ephemeral:$Ephemeral
    $providerVersion=Get-HarnessProviderVersion $providerLaunch
    $mode = "execute"
    if ($PreflightOnly) {
        $mode = "preflight"
    } elseif ($DryRun) {
        $mode = "dry_run"
    }

    $readiness = @"
# Agent Invocation Readiness

## Meta

- assignment_id: $AssignmentId
- owner: $Agent
- mode: $mode
- provider: $provider
- provider_contract_version: 1
- provider_path: $($providerLaunch.executable)
- provider_version: $providerVersion
- assignment_file: $assignmentPath
- packet_file: $packetFile
- prompt_file: $promptFile
- work_area: $workArea
- execution_root: $executionRoot
- worktree_path: $worktreePath
- workspace_action: $workspaceAction
- workspace_status: $workspaceStatus
- feature_branch: $featureBranch
- branch_before: $branchBefore
- branch_after: $branchAfter
- branch_action: $branchAction
- branch_base: $(if ([string]::IsNullOrWhiteSpace($branchBase)) { "none" } else { $branchBase })
- branch_status: $branchStatus
- validation: $validation
"@

    if ($PreflightOnly -or $DryRun) {
        Write-Utf8File -Path $summaryFile -Content $readiness
        if ($DryRun) {
            Write-Utf8File -Path $runLogFile -Content "dry run only; $provider was not started"
            Write-Output "dry run summary: $summaryFile"
        } else {
            Write-Utf8File -Path $runLogFile -Content "preflight only; $provider was not started"
            Write-Output "preflight summary: $summaryFile"
        }
        $previewTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $previewEntry = @"
- time: $previewTimestamp
  - assignment_id: $AssignmentId
  - owner: $Agent
  - mode: $mode
  - result: not-run
  - feature_branch: $featureBranch
  - branch_status: $branchStatus
  - summary: $summaryFile
"@
        Append-Utf8File -Path $liveDispatchLog -Content $previewEntry
        exit 0
    }

    $startTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    try {
        $workerIntent = New-AssignmentWorkerIntent -RootDir $rootDir -Owner $Agent -AssignmentId $AssignmentId -InvokeLease $invokeLock -Executable $providerLaunch.executable -Arguments $providerLaunch.arguments -PromptFile $promptFile -LogFile $runLogFile -ExecutionRoot $executionRoot -ProviderContract $providerLaunch.contract
    } catch {
        # A policy/accounting refusal is not an implementation failure. Keep the
        # claimed assignment available for an explicit retry after inspection.
        $launchIntentFailed = $true
        throw
    }
    $workerResult = Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot 'run_assignment_worker.ps1') -Arguments @('-RootDir', $rootDir, '-AssignmentId', $AssignmentId, '-InvocationId', $workerIntent.invocation_id) -AllowFailure
    $workerRecord = Get-AssignmentWorkerRecord $rootDir $AssignmentId
    if ($workerRecord.invocation_id -cne $workerIntent.invocation_id -or $workerRecord.status -cne 'exited') { throw 'worker exit is unconfirmed; assignment remains quarantined' }
    $exitCode = $workerRecord.exit_code
    Export-HarnessProviderLastMessage $workerRecord $runLogFile $lastMessageFile
    $runLogText = [IO.File]::ReadAllText($runLogFile)

	    $doneAfterRun = Get-ChildItem -LiteralPath $ownerDirs.Done -File -ErrorAction SilentlyContinue |
	        Where-Object { $_.BaseName -like ($AssignmentId + "__*") } |
	        Select-Object -First 1

	    $completionStatus = "worker_completed_assignment"
	    if ($null -eq $doneAfterRun) {
	        $completionStatus = "worker_did_not_complete_assignment_marked_fail"
	        $runLogText += [Environment]::NewLine + [Environment]::NewLine + "Harness auto-completion: worker did not complete the assignment; marking it as fail."
	        Write-Utf8File -Path $runLogFile -Content $runLogText
	        $autoCompleteResult = Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot "complete_assignment.ps1") -Arguments @("-Agent", $Agent, "-AssignmentId", $AssignmentId, "-Result", "fail") -AllowFailure
	        if (-not $autoCompleteResult.Success) {
	            $completionStatus = "auto_complete_failed"
	            throw "worker did not complete assignment and harness failed to mark it fail: $AssignmentId`n$($autoCompleteResult.Output)"
	        }
	    }

	    $finalAssignmentFile = Get-ChildItem -LiteralPath $ownerDirs.Done -File -ErrorAction SilentlyContinue |
	        Where-Object { $_.BaseName -like ($AssignmentId + "__*") } |
	        Select-Object -First 1
    $finalResult = "unknown"
    if ($null -ne $finalAssignmentFile) {
        $finalContent = Get-Content -Encoding UTF8 -LiteralPath $finalAssignmentFile.FullName
        $finalResult = Get-MarkdownValue -Content $finalContent -Key "result"
        if($finalResult -eq 'pass'){Assert-AssignmentCompletionEvidence $rootDir $Agent $AssignmentId ([IO.File]::ReadAllText($finalAssignmentFile.FullName)) | Out-Null}
    }

    $lastMessage = ""
    if (Test-Path -LiteralPath $lastMessageFile) {
        $lastMessage = Get-Content -Raw -Encoding UTF8 -LiteralPath $lastMessageFile
    }

    $summary = @"
# Agent Run Summary

## Meta

- assignment_id: $AssignmentId
- owner: $Agent
- exit_code: $exitCode
- provider: $provider
- provider_execution_status: $($workerRecord.provider_result.execution_status)
- provider_response_status: $($workerRecord.provider_result.response_status)
- provider_error_kind: $($workerRecord.provider_result.error_kind)
- result: $finalResult
- work_area: $workArea
- execution_root: $executionRoot
	- worktree_path: $worktreePath
	- workspace_action: $workspaceAction
	- workspace_status: $workspaceStatus
	- completion_status: $completionStatus
	- feature_branch: $featureBranch
	- branch_before: $branchBefore
	- branch_after: $branchAfter
- branch_action: $branchAction
- branch_base: $(if ([string]::IsNullOrWhiteSpace($branchBase)) { "none" } else { $branchBase })

## Files

- packet: $packetFile
- prompt: $promptFile
- run_log: $runLogFile
- last_message: $lastMessageFile

## Validation

- command: $validation

## Last Message

$lastMessage
"@
    Write-Utf8File -Path $summaryFile -Content $summary

    $finishTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = @"
- time: $finishTimestamp
  - assignment_id: $AssignmentId
  - owner: $Agent
  - started_at: $startTimestamp
  - exit_code: $exitCode
  - result: $finalResult
  - feature_branch: $featureBranch
  - summary: $summaryFile
  - run_log: $runLogFile
"@
    Append-Utf8File -Path $liveDispatchLog -Content $entry
    Set-AssignmentWorkerSettled $rootDir $AssignmentId $workerIntent.invocation_id $invokeLock

	    Write-Output "$provider run summary: $summaryFile"
	    if ($finalResult -ne "pass") {
	        exit 1
	    }
	    if ($exitCode -ne 0) {
	        exit $exitCode
	    }
	} catch {
    if (-not $DryRun -and -not $PreflightOnly -and -not $launchIntentFailed -and -not (Test-AssignmentWorkerUnsettled $rootDir $AssignmentId)) {
        $doneAfterFailure = Get-ChildItem -LiteralPath $ownerDirs.Done -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -like ($AssignmentId + "__*") } |
            Select-Object -First 1
        $progressAfterFailure = Get-AssignmentFilePath -BaseDir $ownerDirs.InProgress -Id $AssignmentId
	        if ($null -eq $doneAfterFailure -and $null -ne $progressAfterFailure) {
	            $markFailResult = Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot "complete_assignment.ps1") -Arguments @("-Agent", $Agent, "-AssignmentId", $AssignmentId, "-Result", "fail") -AllowFailure
	            if (-not $markFailResult.Success) {
	                Write-Warning ("failed to mark assignment as fail after invoke error: " + $markFailResult.Output)
	            }
	        }
	    }

    throw
} finally {
    Release-HarnessLock -LockPath $invokeLock
}
