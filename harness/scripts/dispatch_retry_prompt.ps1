param(
    [switch]$InvokeCodex,
    [switch]$Ephemeral,
    [string]$Model,
    [switch]$DryRun,
    [switch]$PreflightOnly,
    [string]$PromptId
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
. (Join-Path $PSScriptRoot "git_workflow_common.ps1")

$rootDir = Get-HarnessRoot -ScriptDirectory $PSScriptRoot
$retryDir = Get-HarnessConfiguredPath -RootDir $rootDir -Name "retry_prompts" -FallbackRelativePath "harness/reports/retry_prompts"
$dispatchLog = Get-HarnessConfiguredPath -RootDir $rootDir -Name "dispatch_log" -FallbackRelativePath "harness/reports/dispatch_log.md"
$assignmentsRoot = Get-HarnessConfiguredPath -RootDir $rootDir -Name "assignments_root" -FallbackRelativePath "harness/assignments"
$dispatchPackets = Get-HarnessConfiguredPath -RootDir $rootDir -Name "dispatch_packets" -FallbackRelativePath "harness/reports/dispatch_packets"
$lockRoot = Get-HarnessLockRoot -RootDir $rootDir
$latestReport = Get-HarnessConfiguredPath -RootDir $rootDir -Name "latest_report" -FallbackRelativePath "harness/reports/latest_report.md"

if (-not (Test-Path -LiteralPath $retryDir)) {
    throw "retry prompt directory not found: $retryDir"
}

if (-not (Test-Path -LiteralPath $dispatchLog)) {
    Write-Utf8File -Path $dispatchLog -Content "# Dispatch Log`n`n## Entries`n"
}

Ensure-HarnessDirectory -Path $dispatchPackets

function Invoke-AssignmentWorker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Owner,
        [Parameter(Mandatory = $true)]
        [string]$CurrentAssignmentId
    )

    $invokeScript = Join-Path $PSScriptRoot "invoke_assignment_codex.ps1"
    $invokeArgs = @(
        "-Agent", $Owner,
        "-AssignmentId", $CurrentAssignmentId
    )
    if ($Ephemeral) {
        $invokeArgs += "-Ephemeral"
    }
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $invokeArgs += @("-Model", $Model)
    }
    if ($DryRun) {
        $invokeArgs += "-DryRun"
    }
    if ($PreflightOnly) {
        $invokeArgs += "-PreflightOnly"
    }

    $invokeResult = Invoke-HarnessPowerShellFile -FilePath $invokeScript -Arguments $invokeArgs -AllowFailure
    if (-not [string]::IsNullOrWhiteSpace($invokeResult.Output)) {
        Write-Output $invokeResult.Output
    }
    if (-not $invokeResult.Success) {
        exit $invokeResult.ExitCode
    }
}

$latestPrompt = $null
if (-not [string]::IsNullOrWhiteSpace($PromptId)) {
    $latestPrompt = Get-ChildItem -LiteralPath $retryDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne ".gitkeep" -and $_.BaseName -eq $PromptId } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
} else {
    if (-not (Test-Path -LiteralPath $latestReport)) {
        throw "latest report not found: $latestReport"
    }

    $reportContent = Get-Content -LiteralPath $latestReport
    $reportStatus = Get-MarkdownValue -Content $reportContent -Key "status"
    $reportCycle = Get-MarkdownValue -Content $reportContent -Key "last_cycle"

    if ($reportStatus -eq "pass" -or $reportStatus -eq "partial-pass") {
        Write-Output "latest report is pass; dispatch not needed"
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($reportCycle) -or $reportCycle -eq "none") {
        throw "latest report does not include a valid last_cycle value"
    }

    $latestPrompt = Get-ChildItem -LiteralPath $retryDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne ".gitkeep" } |
        Sort-Object LastWriteTime -Descending |
        Where-Object {
            $promptContent = Get-Content -LiteralPath $_.FullName
            (Get-MarkdownValue -Content $promptContent -Key "source_cycle") -eq $reportCycle
        } |
        Select-Object -First 1
}

if ($null -eq $latestPrompt) {
    if (-not [string]::IsNullOrWhiteSpace($PromptId)) {
        Write-Output "retry prompt not found for prompt_id: $PromptId"
    } else {
        Write-Output "no retry prompt found for the latest failing cycle"
    }
    exit 0
}

$content = Get-Content -LiteralPath $latestPrompt.FullName
$promptId = Get-MarkdownValue -Content $content -Key "prompt_id"
$owner = Get-MarkdownValue -Content $content -Key "agent"
$failureType = Get-MarkdownValue -Content $content -Key "type"
$module = Get-MarkdownValue -Content $content -Key "module"
$validation = Get-MarkdownValue -Content $content -Key "command"
$task = Get-MarkdownValue -Content $content -Key "task"
$attempt = Get-MarkdownValue -Content $content -Key "attempt"
$failureSignature = Get-MarkdownValue -Content $content -Key "failure_signature"

if ([string]::IsNullOrWhiteSpace($promptId)) {
    $promptId = [System.IO.Path]::GetFileNameWithoutExtension($latestPrompt.Name)
}

if ([string]::IsNullOrWhiteSpace($owner)) {
    $owner = "manager-main"
}

if ([string]::IsNullOrWhiteSpace($failureSignature)) {
    $failureSignature = Get-FailureSignature -FailureType $failureType -FailureModule $module -Task $task
}

$reason = "owner accepted from retry prompt"
$escalation = "no"

if ($failureType -eq "compile") {
    $owner = Get-DispatchConfigValue -RootDir $rootDir -Name "compile_owner" -Fallback "manager-main"
    $reason = "compile failures are escalated first"
    $escalation = "yes"
} elseif ($failureType -eq "interface") {
    $owner = Get-DispatchConfigValue -RootDir $rootDir -Name "interface_owner" -Fallback "manager-main"
    $reason = "interface failures require cross-module coordination"
    $escalation = "yes"
} elseif ($failureType -eq "environment") {
    $owner = Get-DispatchConfigValue -RootDir $rootDir -Name "environment_owner" -Fallback "manager-harness"
    $reason = "environment failures belong to harness operations"
}

$consecutiveFailures = Get-ConsecutiveFailureCount -AssignmentsRoot $assignmentsRoot -FailureSignature $failureSignature
if ($consecutiveFailures -ge 2 -and $failureType -ne "environment") {
    $owner = Get-DispatchConfigValue -RootDir $rootDir -Name "repeat_failure_escalation_owner" -Fallback "manager-main"
    $reason = "escalated after repeated failed attempts for the same failure signature"
    $escalation = "yes"
}

$dispatchLock = Acquire-HarnessLock -LockRoot $lockRoot -LockName ("dispatch_" + $promptId) -MaxAgeSeconds 1800
if ($null -eq $dispatchLock) {
    Write-Output "dispatch lock is already held for prompt: $promptId"
    exit 0
}

try {
    $ownerDirs = Get-AssignmentDirectories -RootDir $rootDir -Owner $owner
    $queueLease = Enter-AssignmentQueue $rootDir $owner
    Release-HarnessLock $queueLease
    $existingAssignment = Get-ChildItem -LiteralPath $assignmentsRoot -Recurse -Filter '*.md' -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -like "${promptId}__*" -and
            (Split-Path -Leaf $_.DirectoryName) -ne "done"
        } |
        Select-Object -First 1

    if ($null -ne $existingAssignment) {
        Write-Output "assignment already pending: $($existingAssignment.FullName)"
        if ($InvokeCodex) {
            $existingContent = Get-Content -LiteralPath $existingAssignment.FullName
            $existingOwner = Get-MarkdownValue -Content $existingContent -Key "owner"
            $existingId = Get-MarkdownValue -Content $existingContent -Key "assignment_id"
            if ([string]::IsNullOrWhiteSpace($existingOwner)) {
                $existingOwner = $owner
            }
            if ([string]::IsNullOrWhiteSpace($existingId)) {
                $existingId = $existingAssignment.BaseName
            }
            Invoke-AssignmentWorker -Owner $existingOwner -CurrentAssignmentId $existingId
        }
        exit 0
    }

    $dispatchFileStamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $assignmentId = "${promptId}__${dispatchFileStamp}"
    $assignmentFile = Join-Path $ownerDirs.Inbox ($assignmentId + ".md")
    $handoffContext = Get-OwnerHandoffContext -Owner $owner -RootDir $rootDir
    $promptText = ($content -join [Environment]::NewLine)
    $workArea = $handoffContext.WorkArea
    $readFirstList = (($handoffContext.Read | ForEach-Object { "- $_" }) -join [Environment]::NewLine)
    $featureBranch = Get-GitExpectedAssignmentBranch -RootDir $rootDir -Owner $owner -AssignmentId $assignmentId
    $invokeCommand = (Convert-HarnessLayoutText $rootDir "pwsh -NoProfile -File harness/scripts/invoke_assignment_codex.ps1 -Agent $owner -AssignmentId $assignmentId")

    $assignmentBody = @"
# Assignment

## Meta

- assignment_id: $assignmentId
- source_prompt: $($latestPrompt.Name)
- owner: $owner
- status: inbox
- feature_branch: $featureBranch
- failure_type: $failureType
- module: $module
- validation: $validation
- escalation: $escalation
- attempt: $attempt
- failure_signature: $failureSignature
- result: pending

## Task

- task: $task

## Handoff Packet

- read: $($handoffContext.Read -join ", ")
- work_area: $workArea

## Retry Prompt

$promptText
"@
    Write-Utf8File -Path $assignmentFile -Content $assignmentBody

    $packetFile = Join-Path $dispatchPackets ($assignmentId + ".md")
    $relativeAssignmentFile = Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $assignmentFile
    $relativePacketFile = Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $packetFile
    $packetBody = @"
# Dispatch Packet

## Target

- owner: $owner
- assignment_id: $assignmentId
- work_area: $workArea
- feature_branch: $featureBranch
- assignment_file: $relativeAssignmentFile

## Read First

$readFirstList

## Task

- task: $task
- validation: $validation

## Git Context

- feature_branch: $featureBranch
- rule: live execution must happen on the assignment feature branch, not on main, dev, or test branches
- worktree_mode: each live assignment runs in its own isolated git worktree under harness/state/worktrees

## Send This To The Subagent

Read the listed docs first. Then claim assignment $assignmentId, work only in $workArea unless interface updates are required, validate with $validation, and complete assignment $assignmentId with the correct result.

## Live Codex Invocation

- command: $invokeCommand
- note: run this from the repository root to hand the assignment to a live Codex worker; the runner will create or reuse an isolated worktree for $featureBranch
"@
    Write-Utf8File -Path $packetFile -Content $packetBody

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = @"
- time: $timestamp
  - prompt: $($latestPrompt.Name)
  - prompt_id: $promptId
  - owner: $owner
  - failure_type: $failureType
  - module: $module
  - reason: $reason
  - validation: $validation
  - escalation: $escalation
  - assignment_id: $assignmentId
  - assignment: $relativeAssignmentFile
  - packet: $relativePacketFile
"@
    Append-Utf8File -Path $dispatchLog -Content $entry

    Write-Output "selected prompt: $($latestPrompt.FullName)"
    Write-Output "selected owner: $owner"
    Write-Output "reason: $reason"
    Write-Output "validation: $validation"
    Write-Output "escalation: $escalation"
    Write-Output "assignment_id: $assignmentId"
    Write-Output "assignment: $assignmentFile"
    Write-Output "packet: $packetFile"

    if ($InvokeCodex) {
        Invoke-AssignmentWorker -Owner $owner -CurrentAssignmentId $assignmentId
    }
} finally {
    Release-HarnessLock -LockPath $dispatchLock
}
