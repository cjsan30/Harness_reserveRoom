param(
    [string]$PlanFile,
    [int]$StaleAfterSeconds = 7200,
    [switch]$RecoverStale,
    [switch]$Json,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")

$rootDir = Get-HarnessRoot -ScriptDirectory $PSScriptRoot
$seedPlansDir = Get-HarnessConfiguredPath -RootDir $rootDir -Name "seed_plans" -FallbackRelativePath "harness/reports/seed_plans"
$assignmentsRoot = Get-HarnessConfiguredPath -RootDir $rootDir -Name "assignments_root" -FallbackRelativePath "harness/assignments"

function ConvertTo-SafeSeedToken {
    param([Parameter(Mandatory = $true)][string]$Value)

    $token = $Value.ToLowerInvariant() -replace "[^a-z0-9/_-]", "-"
    $token = $token -replace "-{2,}", "-"
    $token = $token.Trim('-', '/')
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "cannot derive a safe seed token from value: $Value"
    }

    return $token
}

function Resolve-SeedPlanPath {
    param([string]$RequestedPlanFile)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPlanFile)) {
        return Resolve-ProjectPath -RootDir $rootDir -ProjectPath $RequestedPlanFile -Label "seed.plan_file"
    }

    if (-not (Test-Path -LiteralPath $seedPlansDir)) {
        return ""
    }

    $latestPlan = Get-ChildItem -LiteralPath $seedPlansDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne ".gitkeep" -and $_.Name -notlike "*__dispatch_summary.md" -and $_.Name -notlike "*__resume.md" -and $_.Name -notlike "*__resume.json" } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $latestPlan) {
        return ""
    }

    return $latestPlan.FullName
}

function Get-MarkdownSectionText {
    param(
        [Parameter(Mandatory = $true)]
        $Lines,
        [Parameter(Mandatory = $true)]
        [string]$SectionName
    )

    $normalizedLines = @($Lines | ForEach-Object { [string]$_ })
    $sectionHeader = "### $SectionName"
    $startIndex = -1
    for ($i = 0; $i -lt $normalizedLines.Count; $i++) {
        if ($normalizedLines[$i].Trim() -eq $sectionHeader) {
            $startIndex = $i + 1
            break
        }
    }

    if ($startIndex -lt 0 -or $startIndex -ge $normalizedLines.Count) {
        return ""
    }

    $endIndex = $normalizedLines.Count
    for ($i = $startIndex; $i -lt $normalizedLines.Count; $i++) {
        $trimmed = $normalizedLines[$i].Trim()
        if ($trimmed.StartsWith("### ") -or $trimmed.StartsWith("## ")) {
            $endIndex = $i
            break
        }
    }

    if ($endIndex -le $startIndex) {
        return ""
    }

    return (@($normalizedLines[$startIndex..($endIndex - 1)]) -join [Environment]::NewLine).Trim()
}

function Get-SeedAssignmentBlocks {
    param([Parameter(Mandatory = $true)]$Content)

    $normalizedContent = @($Content | ForEach-Object { [string]$_ })
    $blocks = @()
    $currentLines = @()
    $insideAssignment = $false
    $blockIndex = 0

    foreach ($line in $normalizedContent) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "## Assignment") {
            if ($insideAssignment) {
                $blockIndex += 1
                $blocks += [pscustomobject]@{ Index = $blockIndex; Lines = @($currentLines) }
                $currentLines = @()
            }
            $insideAssignment = $true
            continue
        }

        if (-not $insideAssignment) {
            continue
        }

        if ($trimmed.StartsWith("## ") -and $trimmed -ne "## Assignment") {
            $blockIndex += 1
            $blocks += [pscustomobject]@{ Index = $blockIndex; Lines = @($currentLines) }
            $currentLines = @()
            $insideAssignment = $false
            continue
        }

        $currentLines += $line
    }

    if ($insideAssignment) {
        $blockIndex += 1
        $blocks += [pscustomobject]@{ Index = $blockIndex; Lines = @($currentLines) }
    }

    return $blocks
}

function Get-SeedAssignmentDefinition {
    param([Parameter(Mandatory = $true)]$Block)

    $lines = @($Block.Lines)
    return [pscustomobject]@{
        Index = [int]$Block.Index
        Owner = Get-MarkdownValue -Content $lines -Key "owner"
        Title = Get-MarkdownValue -Content $lines -Key "title"
        Task = Get-MarkdownSectionText -Lines $lines -SectionName "Task"
    }
}

function Get-SeedTaskFiles {
    param(
        [Parameter(Mandatory = $true)][string]$PlanId,
        [Parameter(Mandatory = $true)][string]$TaskKey
    )

    if (-not (Test-Path -LiteralPath $assignmentsRoot)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $assignmentsRoot -Recurse -Filter '*.md' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Where-Object {
            $content = Get-Content -LiteralPath $_.FullName
            (Get-MarkdownValue -Content $content -Key "source_plan_id") -eq $PlanId -and
                (Get-MarkdownValue -Content $content -Key "seed_task_key") -eq $TaskKey
        })
}

function Get-AssignmentStateFromFile {
    param([Parameter(Mandatory = $true)]$File)

    $content = Get-Content -LiteralPath $File.FullName
    $assignmentId = Get-MarkdownValue -Content $content -Key "assignment_id"
    if ([string]::IsNullOrWhiteSpace($assignmentId)) {
        $assignmentId = $File.BaseName -replace "__(pass|fail)$", ""
    }
    $result = Get-MarkdownValue -Content $content -Key "result"
    if ([string]::IsNullOrWhiteSpace($result)) {
        $result = "pending"
    }

    $dirName = Split-Path -Leaf $File.DirectoryName
    $state = $dirName
    if ($dirName -eq "done") {
        $state = "done"
    }

    return [pscustomobject]@{
        AssignmentId = $assignmentId
        State = $state
        Result = $result
        File = $File.FullName
        LastWriteTimeUtc = $File.LastWriteTimeUtc
        Content = $content
    }
}

function Select-SeedTaskState {
    param([Parameter(Mandatory = $true)][object[]]$States)

    $passed = $States | Where-Object { $_.State -eq "done" -and $_.Result -eq "pass" } | Select-Object -First 1
    if ($null -ne $passed) { return $passed }

    $inProgress = $States | Where-Object { $_.State -eq "in_progress" } | Select-Object -First 1
    if ($null -ne $inProgress) { return $inProgress }

    $inbox = $States | Where-Object { $_.State -eq "inbox" } | Select-Object -First 1
    if ($null -ne $inbox) { return $inbox }

    $failed = $States | Where-Object { $_.State -eq "done" -and $_.Result -eq "fail" } | Select-Object -First 1
    if ($null -ne $failed) { return $failed }

    return $null
}

$planPath = Resolve-SeedPlanPath -RequestedPlanFile $PlanFile
if ([string]::IsNullOrWhiteSpace($planPath)) {
    throw "no seed plan found"
}

$planContent = Get-Content -LiteralPath $planPath
$planId = Get-MarkdownValue -Content $planContent -Key "plan_id"
if ([string]::IsNullOrWhiteSpace($planId)) {
    $planId = [System.IO.Path]::GetFileNameWithoutExtension($planPath)
}
$planId = ConvertTo-SafeSeedToken -Value $planId
$relativePlanPath = Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $planPath
$resumeReportPath = Join-Path $seedPlansDir ($planId + "__resume.md")
$resumeJsonPath = Join-Path $seedPlansDir ($planId + "__resume.json")
$resumeCommand = (Convert-HarnessLayoutText $rootDir "pwsh -NoProfile -File harness/scripts/run_seed_handoff.ps1 -Resume -PlanFile $relativePlanPath")

$assignmentBlocks = Get-SeedAssignmentBlocks -Content $planContent
if ($assignmentBlocks.Count -eq 0) {
    throw "seed plan does not contain any '## Assignment' blocks: $planPath"
}

if ($RecoverStale) {
    $ownersToRecover = @($assignmentBlocks |
        ForEach-Object { Get-SeedAssignmentDefinition -Block $_ } |
        ForEach-Object { $_.Owner } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique)
    foreach ($owner in $ownersToRecover) {
        Restore-StaleInProgressAssignments -RootDir $rootDir -Owner $owner -StaleAfterSeconds $StaleAfterSeconds | Out-Null
    }
}

$rows = New-Object System.Collections.Generic.List[object]
$passedCount = 0
$pendingCount = 0
$runningCount = 0
$failedCount = 0
$missingCount = 0
$recoverableCount = 0

foreach ($block in $assignmentBlocks) {
    $definition = Get-SeedAssignmentDefinition -Block $block
    $taskKey = ($definition.Owner + "|" + $definition.Title.Trim()).ToLowerInvariant()
    $files = Get-SeedTaskFiles -PlanId $planId -TaskKey $taskKey
    $states = @($files | ForEach-Object { Get-AssignmentStateFromFile -File $_ })
    $selected = Select-SeedTaskState -States $states

    $state = "missing"
    $result = "unknown"
    $assignmentId = ("{0}__{1:d2}__{2}" -f $planId, $definition.Index, (ConvertTo-SafeSeedToken -Value $definition.Title))
    $assignmentPath = "none"
    $activeInvokeLock = $false
    $ageSeconds = 0
    $nextAction = "create assignment from seed plan"
    $nextCommand = $resumeCommand

    if ($null -ne $selected) {
        $state = $selected.State
        $result = $selected.Result
        $assignmentId = $selected.AssignmentId
        $assignmentPath = Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $selected.File
        $ageSeconds = [math]::Round(((Get-Date).ToUniversalTime() - $selected.LastWriteTimeUtc).TotalSeconds)

        if (Test-AssignmentQueueUnresolved $rootDir $definition.Owner) {
            $recoverableCount += 1
            $state = 'queue_unresolved'
            $nextAction = 'reconcile queue journal before trusting completion'
            $nextCommand = (Convert-HarnessLayoutText $rootDir "pwsh -NoProfile -File harness/scripts/repair_assignment_state.ps1 -Agent $($definition.Owner)")
        } elseif (Test-AssignmentWorkerUnsettled $rootDir $assignmentId) {
            $runningCount += 1
            $state = 'worker_unresolved'
            $nextAction = 'wait for worker exit, then reconcile; never infer exit from parent death'
            $nextCommand = (Convert-HarnessLayoutText $rootDir "pwsh -NoProfile -File harness/scripts/repair_assignment_state.ps1 -Agent $($definition.Owner) -AssignmentId $assignmentId")
        } elseif ($state -eq "done" -and $result -eq "pass") {
            try {
                Assert-AssignmentCompletionEvidence $rootDir $definition.Owner $assignmentId ([IO.File]::ReadAllText($selected.File)) | Out-Null
                $passedCount += 1
                $nextAction = "skip; assignment passed with current execution evidence"
                $nextCommand = "none"
            } catch {
                $recoverableCount += 1
                $state='validation_unverified';$result='unverified'
                $nextAction='inspect missing, stale or invalid completion evidence; no automatic rerun or promotion'
                $nextCommand='none'
            }
        } elseif ($state -eq "done" -and $result -eq "fail") {
            $failedCount += 1
            $nextAction = "resume with previous failure analysis"
        } elseif ($state -eq "inbox") {
            $pendingCount += 1
            $nextAction = "invoke pending assignment"
        } elseif ($state -eq "in_progress") {
            $invokeLockPath = Get-AssignmentInvokeLockPath -RootDir $rootDir -AssignmentId $assignmentId
            $activeInvokeLock = Test-HarnessLockActive -LockPath $invokeLockPath -MaxAgeSeconds $StaleAfterSeconds
            if ($activeInvokeLock) {
                $runningCount += 1
                $nextAction = "wait for active worker or inspect live dispatch log"
                $nextCommand = (Convert-HarnessLayoutText $rootDir "pwsh -NoProfile -File harness/scripts/get_seed_handoff_resume.ps1 -PlanFile $relativePlanPath")
            } else {
                $recoverableCount += 1
                $nextAction = "recover stale in_progress assignment, then resume"
                $nextCommand = (Convert-HarnessLayoutText $rootDir "pwsh -NoProfile -File harness/scripts/get_seed_handoff_resume.ps1 -PlanFile $relativePlanPath -RecoverStale")
            }
        }
    } else {
        $missingCount += 1
    }

    $rows.Add([pscustomobject]@{
        index = $definition.Index
        owner = $definition.Owner
        title = $definition.Title
        assignment_id = $assignmentId
        state = $state
        result = $result
        assignment = $assignmentPath
        active_invoke_lock = $activeInvokeLock
        age_seconds = $ageSeconds
        next_action = $nextAction
        next_command = $nextCommand
    }) | Out-Null
}

$overallStatus = "resumable"
if ($passedCount -eq $assignmentBlocks.Count) {
    $overallStatus = "complete"
} elseif ($runningCount -gt 0) {
    $overallStatus = "running"
} elseif ($recoverableCount -gt 0) {
    $overallStatus = "needs_recovery"
}

$object = [pscustomobject]@{
    status = $overallStatus
    plan_file = $relativePlanPath
    plan_id = $planId
    generated_at = (Get-Date).ToString("o")
    stale_after_seconds = $StaleAfterSeconds
    recover_stale = $RecoverStale.IsPresent
    resume_command = $resumeCommand
    counts = [pscustomobject]@{
        total = $assignmentBlocks.Count
        passed = $passedCount
        pending = $pendingCount
        running = $runningCount
        failed = $failedCount
        missing = $missingCount
        recoverable = $recoverableCount
    }
    assignments = @($rows.ToArray())
    reports = [pscustomobject]@{
        resume_markdown = Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $resumeReportPath
        resume_json = Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $resumeJsonPath
    }
}

$jsonText = $object | ConvertTo-Json -Depth 10
Write-Utf8File -Path $resumeJsonPath -Content $jsonText

$rowText = if ($rows.Count -eq 0) {
    "- none"
} else {
    ($rows | ForEach-Object {
        @(
            "- index: $($_.index)"
            "  - owner: $($_.owner)"
            "  - title: $($_.title)"
            "  - assignment_id: $($_.assignment_id)"
            "  - state: $($_.state)"
            "  - result: $($_.result)"
            "  - active_invoke_lock: $($_.active_invoke_lock)"
            "  - assignment: $($_.assignment)"
            "  - next_action: $($_.next_action)"
            "  - next_command: $($_.next_command)"
        ) -join [Environment]::NewLine
    }) -join [Environment]::NewLine
}

$markdown = @"
# Seed Handoff Resume

## Summary

- status: $overallStatus
- plan_file: $relativePlanPath
- plan_id: $planId
- generated_at: $($object.generated_at)
- stale_after_seconds: $StaleAfterSeconds
- recover_stale: $($RecoverStale.IsPresent)

## Resume Command

    $resumeCommand

## Counts

- total: $($assignmentBlocks.Count)
- passed: $passedCount
- pending: $pendingCount
- running: $runningCount
- failed: $failedCount
- missing: $missingCount
- recoverable: $recoverableCount

## Assignments

$rowText
"@
Write-Utf8File -Path $resumeReportPath -Content $markdown

if ($Json) {
    Write-Output $jsonText
} elseif (-not $Quiet) {
    Write-Output "status: $overallStatus"
    Write-Output "plan: $planPath"
    Write-Output "resume_report: $resumeReportPath"
    Write-Output "resume_json: $resumeJsonPath"
    Write-Output "resume_command: $resumeCommand"
}
