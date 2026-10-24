param(
    [switch]$Quiet,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")

$rootDir = Get-HarnessRoot -ScriptDirectory $PSScriptRoot

function Resolve-OptionalPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectPath,
        [string]$Label = "path"
    )

    try {
        return Resolve-HarnessEnginePath -RootDir $rootDir -ProjectPath $ProjectPath -Label $Label
    } catch {
        return [System.IO.Path]::GetFullPath((Join-Path $rootDir $ProjectPath))
    }
}

function Get-ReportValue {
    param(
        [string]$Path,
        [string]$Key
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    return Get-MarkdownValue -Content @(Get-Content -LiteralPath $Path) -Key $Key
}

function Get-RelativeOrNone {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return "none"
    }

    try {
        return Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $Path
    } catch {
        return $Path
    }
}

function Get-RelativePathText {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return "none"
    }

    try {
        return Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $Path
    } catch {
        return $Path
    }
}

function Add-TextItem {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$List,
        [string]$Value
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $List.Add($Value) | Out-Null
    }
}

function Test-GitHeadAvailable {
    $result = Invoke-HarnessProcess -Executable "git" -Arguments @("rev-parse", "--verify", "HEAD") -WorkingDirectory $rootDir -AllowFailure
    return $result.Success
}

function Get-StatusFailureClassification {
    param(
        [string]$KnownType = "",
        [string]$Text = ""
    )

    $combined = (($KnownType + "`n" + $Text) -replace "\r?\n", " ").Trim()
    $type = if ([string]::IsNullOrWhiteSpace($KnownType) -or $KnownType -eq "none") { "unknown" } else { $KnownType }

    if ($combined -match "(?i)(missing environment variable|api key|secret|token|password|DATABASE_URL|OPENAI_API_KEY|401 Unauthorized|403 Forbidden|authentication required)") {
        $type = "secret"
    } elseif ($combined -match "(?i)(ambiguous requirement|requirements unclear|needs clarification|product decision|project_intake_questions|intake review)") {
        $type = "requirements"
    } elseif ($combined -match "(?i)(worker_did_not_complete|worker did not complete|assignment was not completed|assignment failed after|previous failed assignment requires resume|active invoke lock|codex run summary)") {
        $type = "worker"
    } elseif ($combined -match "(?i)(command not found|No such file|Permission denied|Access is denied|ECONNREFUSED|ETIMEDOUT|ENOTFOUND|network timeout)") {
        $type = "environment"
    }

    $userActionRequired = $false
    $retryable = $true
    $nextAction = "rerun the relevant harness handoff after reviewing the failure summary"

    switch ($type) {
        "secret" {
            $userActionRequired = $true
            $retryable = $false
            $nextAction = "provide missing env values outside Git or update docs/env_manifest.md with a mock/fallback strategy"
            break
        }
        "requirements" {
            $userActionRequired = $true
            $retryable = $false
            $nextAction = "update docs/project_intake.md and rerun intake review before continuing"
            break
        }
        "environment" {
            $userActionRequired = $true
            $retryable = $false
            $nextAction = "fix local toolchain, permissions, or network setup, then rerun validation"
            break
        }
        "worker" {
            $nextAction = "retry the assignment; the retry packet should include Previous Failure Analysis"
            break
        }
        "compile" {
            $nextAction = "dispatch compile/interface repair through retry handoff"
            break
        }
        "interface" {
            $nextAction = "dispatch interface reconciliation through retry handoff"
            break
        }
        default {
            if ($type -eq "unknown") {
                $retryable = $false
                $nextAction = "inspect the latest report before choosing retry or user action"
            }
            break
        }
    }

    return [pscustomobject]@{
        type = $type
        retryable = $retryable
        user_action_required = $userActionRequired
        next_action = $nextAction
        message = $Text
    }
}

$statusJsonPath = Get-HarnessConfiguredPath -RootDir $rootDir -Name "status_json" -FallbackRelativePath "harness/reports/status.json"
$statusMarkdownPath = Get-HarnessConfiguredPath -RootDir $rootDir -Name "status_report" -FallbackRelativePath "harness/reports/status.md"
$intakePath = Resolve-OptionalPath -ProjectPath "docs/project_intake.md" -Label "project intake"
$intakeQuestionsPath = Resolve-OptionalPath -ProjectPath "docs/project_intake_questions.md" -Label "project intake questions"
$envManifestPath = Resolve-OptionalPath -ProjectPath "docs/env_manifest.md" -Label "env manifest"
$envExamplePath = Resolve-OptionalPath -ProjectPath ".env.example" -Label "env example"
$intakeReviewPath = Resolve-OptionalPath -ProjectPath "harness/reports/intake_review_report.md" -Label "intake review report"
$sensitiveReportPath = Resolve-OptionalPath -ProjectPath "harness/reports/sensitive_followups.md" -Label "sensitive followups"
$preflightPath = Get-HarnessConfiguredPath -RootDir $rootDir -Name "preflight_report" -FallbackRelativePath "harness/reports/preflight_report.md"
$latestReportPath = Get-HarnessConfiguredPath -RootDir $rootDir -Name "latest_report" -FallbackRelativePath "harness/reports/latest_report.md"
$seedPlansDir = Get-HarnessConfiguredPath -RootDir $rootDir -Name "seed_plans" -FallbackRelativePath "harness/reports/seed_plans"
$assignmentsRoot = Get-HarnessConfiguredPath -RootDir $rootDir -Name "assignments_root" -FallbackRelativePath "harness/assignments"

$profilePath = ""
try {
    $profilePath = Get-ProjectProfilePath -RootDir $rootDir
} catch {
    $profilePath = ""
}

$latestSeedSummary = ""
if (Test-Path -LiteralPath $seedPlansDir) {
    $latestSeed = Get-ChildItem -LiteralPath $seedPlansDir -File -Filter "*__dispatch_summary.md" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -ne $latestSeed) {
        $latestSeedSummary = $latestSeed.FullName
    }
}

$intakeReviewStatus = Get-ReportValue -Path $intakeReviewPath -Key "status"
$preflightStatus = Get-ReportValue -Path $preflightPath -Key "status"
$cycleStatus = Get-ReportValue -Path $latestReportPath -Key "status"
$cycleFailureType = Get-ReportValue -Path $latestReportPath -Key "type"
$cycleNextOwner = Get-ReportValue -Path $latestReportPath -Key "owner"
$cycleNextTask = Get-ReportValue -Path $latestReportPath -Key "task"
$seedStatus = Get-ReportValue -Path $latestSeedSummary -Key "status"
$seedInvokeMode = Get-ReportValue -Path $latestSeedSummary -Key "invoke_mode"
$seedFailureMessage = Get-ReportValue -Path $latestSeedSummary -Key "message"
$seedPlanFile = Get-ReportValue -Path $latestSeedSummary -Key "plan_file"
$seedPlanId = Get-ReportValue -Path $latestSeedSummary -Key "plan_id"
$seedResumeReportPath = ""
$seedResumeJsonPath = ""
if (-not [string]::IsNullOrWhiteSpace($seedPlanId)) {
    $seedResumeReportPath = Resolve-OptionalPath -ProjectPath ("harness/reports/seed_plans/" + $seedPlanId + "__resume.md") -Label "seed resume report"
    $seedResumeJsonPath = Resolve-OptionalPath -ProjectPath ("harness/reports/seed_plans/" + $seedPlanId + "__resume.json") -Label "seed resume json"
}
$gitHeadExists = Test-GitHeadAvailable

if (-not [string]::IsNullOrWhiteSpace($cycleStatus) -and
    -not [string]::IsNullOrWhiteSpace($profilePath) -and
    (Test-Path -LiteralPath $latestReportPath) -and
    (Test-Path -LiteralPath $profilePath)) {
    $cycleReportTime = (Get-Item -LiteralPath $latestReportPath).LastWriteTimeUtc
    $profileTime = (Get-Item -LiteralPath $profilePath).LastWriteTimeUtc
    if ($cycleReportTime -lt $profileTime) {
        $cycleStatus = "stale"
    }
}

$inboxCount = 0
$inProgressCount = 0
$donePassCount = 0
$doneUnverifiedCount = 0
$doneFailCount = 0
if (Test-Path -LiteralPath $assignmentsRoot) {
    $inboxCount = @(Get-ChildItem -LiteralPath $assignmentsRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match "[/\\]inbox[/\\]" }).Count
    $inProgressCount = @(Get-ChildItem -LiteralPath $assignmentsRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match "[/\\]in_progress[/\\]" }).Count
    foreach($file in @(Get-ChildItem -LiteralPath $assignmentsRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match "[/\\]done[/\\].*__pass\.md$" })) {
        try {
            $owner=Split-Path -Leaf (Split-Path -Parent $file.DirectoryName)
            Assert-AssignmentCompletionEvidence $rootDir $owner ($file.BaseName -replace '__pass$','') ([IO.File]::ReadAllText($file.FullName)) | Out-Null
            $donePassCount++
        } catch {$doneUnverifiedCount++}
    }
    $doneFailCount = @(Get-ChildItem -LiteralPath $assignmentsRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match "[/\\]done[/\\].*__fail\.md$" }).Count
}

$phase = "unknown"
$overallStatus = "unknown"
$userActionRequired = $false
$blocking = New-Object System.Collections.Generic.List[string]
$nonBlocking = New-Object System.Collections.Generic.List[string]
$nextActions = New-Object System.Collections.Generic.List[string]
$nextCommand = ""
$failureClassification = [pscustomobject]@{
    type = "none"
    retryable = $false
    user_action_required = $false
    next_action = "none"
    message = ""
}

if (-not (Test-Path -LiteralPath $intakePath) -and [string]::IsNullOrWhiteSpace($profilePath)) {
    $phase = "setup"
    $overallStatus = "needs_intake"
    $userActionRequired = $true
    Add-TextItem -List $blocking -Value "project intake has not been created"
    Add-TextItem -List $nextActions -Value "create docs/project_intake.md from the intake template"
    $nextCommand = "pwsh -NoProfile -File harness/scripts/start_from_intake.ps1 -CreateTemplate"
} elseif ($intakeReviewStatus -in @("blocked", "needs_input")) {
    $phase = "intake_review"
    $overallStatus = "needs_user_input"
    $userActionRequired = $true
    Add-TextItem -List $blocking -Value "intake review requires more input"
    Add-TextItem -List $nextActions -Value "edit docs/project_intake.md using docs/project_intake_questions.md"
    $nextCommand = "pwsh -NoProfile -File harness/scripts/start_from_intake.ps1 -IntakeFile docs/project_intake.md -Force -RunPreflight -RunSeedDryRun"
} elseif ($intakeReviewStatus -eq "deferred") {
    $phase = "intake_review_deferred"
    $overallStatus = "deferred_questions"
    Add-TextItem -List $nonBlocking -Value "intake has deferred questions; workers may ask later"
    Add-TextItem -List $nextActions -Value "continue only if deferred questions are acceptable"
    $nextCommand = "pwsh -NoProfile -File harness/scripts/start_from_intake.ps1 -IntakeFile docs/project_intake.md -Force -RunPreflight -RunSeedDryRun -AllowDeferredClarifications"
} elseif ([string]::IsNullOrWhiteSpace($profilePath)) {
    $phase = "adapter_init"
    $overallStatus = "needs_profile"
    Add-TextItem -List $nextActions -Value "run intake start to generate the project profile"
    $nextCommand = "pwsh -NoProfile -File harness/scripts/start_from_intake.ps1 -IntakeFile docs/project_intake.md -Force -RunPreflight -RunSeedDryRun"
} elseif ([string]::IsNullOrWhiteSpace($preflightStatus)) {
    $phase = "preflight"
    $overallStatus = "needs_preflight"
    Add-TextItem -List $nextActions -Value "run harness preflight"
    $nextCommand = "pwsh -NoProfile -File harness/scripts/run_harness_preflight.ps1"
} elseif ($preflightStatus -ne "pass") {
    $phase = "preflight"
    $overallStatus = "preflight_failed"
    $userActionRequired = $true
    Add-TextItem -List $blocking -Value "preflight failed; inspect harness/reports/preflight_report.md"
    Add-TextItem -List $nextActions -Value "fix reported profile, path, command, or hook issues"
    $nextCommand = "pwsh -NoProfile -File harness/scripts/run_harness_preflight.ps1"
} elseif ($seedStatus -eq "fail") {
    $phase = "seed_handoff"
    $overallStatus = "seed_failed"
    $failureClassification = Get-StatusFailureClassification -Text $seedFailureMessage
    if ($failureClassification.user_action_required) {
        $userActionRequired = $true
    }
    Add-TextItem -List $blocking -Value ("latest seed handoff failed: " + $failureClassification.type)
    Add-TextItem -List $nextActions -Value "inspect the seed dispatch summary and agent run summary"
    Add-TextItem -List $nextActions -Value $failureClassification.next_action
    Add-TextItem -List $nextActions -Value "refresh the seed resume report before rerunning live workers"
    $seedPlanForCommand = if ([string]::IsNullOrWhiteSpace($seedPlanFile)) { "harness/reports/seed_plans/<plan-file>.md" } else { $seedPlanFile }
    if ($failureClassification.retryable) {
        $nextCommand = "pwsh -NoProfile -File harness/scripts/run_seed_handoff.ps1 -Resume -PlanFile $seedPlanForCommand"
    } else {
        $nextCommand = "pwsh -NoProfile -File harness/scripts/get_harness_status.ps1"
    }
} elseif ($seedStatus -eq "pass" -and $seedInvokeMode -eq "dry_run" -and -not $gitHeadExists) {
    $phase = "baseline"
    $overallStatus = "needs_baseline_commit"
    $userActionRequired = $true
    Add-TextItem -List $blocking -Value "live worker dispatch needs a baseline Git commit"
    Add-TextItem -List $nextActions -Value "create the first project commit"
    $nextCommand = "git add . && git commit -m `"bootstrap project with harness`""
} elseif ($seedStatus -eq "pass" -and $seedInvokeMode -eq "dry_run") {
    $phase = "ready_for_live"
    $overallStatus = "ready_for_live"
    Add-TextItem -List $nextActions -Value "run live seed handoff when ready"
    $nextCommand = "pwsh -NoProfile -File harness/scripts/run_seed_handoff.ps1 -PlanFile harness/reports/seed_plans/<plan-file>.md"
} elseif ($seedStatus -eq "pass" -and $seedInvokeMode -eq "live") {
    $phase = "seed_handoff"
    $overallStatus = "seed_live_passed"
    Add-TextItem -List $nextActions -Value "inspect passing assignments and any Git workflow approval request"
    $nextCommand = "pwsh -NoProfile -File harness/scripts/get_harness_status.ps1"
} elseif ($cycleStatus -eq "fail") {
    $phase = "cycle"
    $overallStatus = "cycle_failed"
    $failureClassification = Get-StatusFailureClassification -KnownType $cycleFailureType -Text $cycleNextTask
    if ($failureClassification.user_action_required) {
        $userActionRequired = $true
    }
    Add-TextItem -List $blocking -Value ("latest harness cycle failed: " + $failureClassification.type)
    if (-not [string]::IsNullOrWhiteSpace($cycleNextOwner)) {
        Add-TextItem -List $nextActions -Value ("next owner: " + $cycleNextOwner)
    }
    if (-not [string]::IsNullOrWhiteSpace($cycleNextTask)) {
        Add-TextItem -List $nextActions -Value ("next task: " + $cycleNextTask)
    }
    Add-TextItem -List $nextActions -Value $failureClassification.next_action
    if ($failureClassification.retryable) {
        $nextCommand = "pwsh -NoProfile -File harness/scripts/run_retry_handoff.ps1"
    } else {
        $nextCommand = "pwsh -NoProfile -File harness/scripts/get_harness_status.ps1"
    }
} elseif ($cycleStatus -eq "pass") {
    $phase = "cycle"
    $overallStatus = "cycle_passed"
    Add-TextItem -List $nextActions -Value "continue with seed handoff, retry handoff, or final review as appropriate"
    $nextCommand = "pwsh -NoProfile -File harness/scripts/run_harness_cycle.ps1"
} else {
    $phase = "preflight"
    $overallStatus = "preflight_passed"
    Add-TextItem -List $nextActions -Value "run full cycle or seed handoff dry-run"
    $nextCommand = "pwsh -NoProfile -File harness/scripts/run_harness_cycle.ps1"
}

if (Test-Path -LiteralPath $intakeReviewPath) {
    $sensitiveFollowups = Get-ReportValue -Path $intakeReviewPath -Key "sensitive_followup_count"
    if (-not [string]::IsNullOrWhiteSpace($sensitiveFollowups) -and $sensitiveFollowups -ne "0") {
        Add-TextItem -List $nonBlocking -Value ("sensitive follow-ups recorded for later env setup: " + $sensitiveFollowups)
    }
}

if($doneUnverifiedCount -gt 0){
    $overallStatus='needs_recovery';$phase='validation_unverified';$userActionRequired=$true
    Add-TextItem -List $blocking -Value 'completed assignments have missing, stale or invalid execution evidence'
    Add-TextItem -List $nextActions -Value 'inspect evidence and explicitly revalidate the completed assignment; automatic promotion is blocked'
    $nextCommand=''
}
$statusObject = [pscustomobject]@{
    status = $overallStatus
    phase = $phase
    user_action_required = $userActionRequired
    generated_at = (Get-Date).ToString("o")
    next_command = $nextCommand
    next_actions = @($nextActions)
    blocking = @($blocking)
    non_blocking = @($nonBlocking)
    reports = [pscustomobject]@{
        status_json = Get-RelativePathText -Path $statusJsonPath
        status_markdown = Get-RelativePathText -Path $statusMarkdownPath
        intake_review = Get-RelativeOrNone -Path $intakeReviewPath
        intake_questions = Get-RelativeOrNone -Path $intakeQuestionsPath
        env_manifest = Get-RelativeOrNone -Path $envManifestPath
        env_example = Get-RelativeOrNone -Path $envExamplePath
        sensitive_followups = Get-RelativeOrNone -Path $sensitiveReportPath
        preflight = Get-RelativeOrNone -Path $preflightPath
        latest_cycle = Get-RelativeOrNone -Path $latestReportPath
        seed_summary = Get-RelativeOrNone -Path $latestSeedSummary
        seed_resume = Get-RelativeOrNone -Path $seedResumeReportPath
        seed_resume_json = Get-RelativeOrNone -Path $seedResumeJsonPath
    }
    checks = [pscustomobject]@{
        intake_review = $(if ([string]::IsNullOrWhiteSpace($intakeReviewStatus)) { "missing" } else { $intakeReviewStatus })
        preflight = $(if ([string]::IsNullOrWhiteSpace($preflightStatus)) { "missing" } else { $preflightStatus })
        cycle = $(if ([string]::IsNullOrWhiteSpace($cycleStatus)) { "missing" } else { $cycleStatus })
        seed_handoff = $(if ([string]::IsNullOrWhiteSpace($seedStatus)) { "missing" } else { $seedStatus })
        seed_invoke_mode = $(if ([string]::IsNullOrWhiteSpace($seedInvokeMode)) { "missing" } else { $seedInvokeMode })
        seed_plan = $(if ([string]::IsNullOrWhiteSpace($seedPlanFile)) { "missing" } else { $seedPlanFile })
        git_head_exists = $gitHeadExists
        env_manifest = $(if (Test-Path -LiteralPath $envManifestPath) { "present" } else { "missing" })
    }
    failure = $failureClassification
    assignments = [pscustomobject]@{
        inbox = $inboxCount
        in_progress = $inProgressCount
        done_pass = $donePassCount
        done_unverified = $doneUnverifiedCount
        done_fail = $doneFailCount
    }
}

$nextCommand = Convert-HarnessLayoutText $rootDir $nextCommand
$statusObject.next_command = $nextCommand
$jsonText = $statusObject | ConvertTo-Json -Depth 10
Write-Utf8File -Path $statusJsonPath -Content $jsonText

$listNextActions = if ($nextActions.Count -eq 0) { "- none" } else { ($nextActions | ForEach-Object { "- $_" }) -join [Environment]::NewLine }
$listBlocking = if ($blocking.Count -eq 0) { "- none" } else { ($blocking | ForEach-Object { "- $_" }) -join [Environment]::NewLine }
$listNonBlocking = if ($nonBlocking.Count -eq 0) { "- none" } else { ($nonBlocking | ForEach-Object { "- $_" }) -join [Environment]::NewLine }
$markdownText = @"
# Harness Status

## Summary

- status: $overallStatus
- phase: $phase
- user_action_required: $userActionRequired
- generated_at: $($statusObject.generated_at)

## Next Command

    $nextCommand

## Next Actions

$listNextActions

## Blocking

$listBlocking

## Non-Blocking

$listNonBlocking

## Failure

- type: $($failureClassification.type)
- retryable: $($failureClassification.retryable)
- user_action_required: $($failureClassification.user_action_required)
- next_action: $($failureClassification.next_action)

## Checks

- intake_review: $($statusObject.checks.intake_review)
- preflight: $($statusObject.checks.preflight)
- cycle: $($statusObject.checks.cycle)
- seed_handoff: $($statusObject.checks.seed_handoff)
- seed_invoke_mode: $($statusObject.checks.seed_invoke_mode)
- seed_plan: $($statusObject.checks.seed_plan)
- git_head_exists: $($statusObject.checks.git_head_exists)
- env_manifest: $($statusObject.checks.env_manifest)

## Assignments

- inbox: $inboxCount
- in_progress: $inProgressCount
- done_pass: $donePassCount
- done_unverified: $doneUnverifiedCount
- done_fail: $doneFailCount

## Reports

- status_json: $(Get-RelativePathText -Path $statusJsonPath)
- status_markdown: $(Get-RelativePathText -Path $statusMarkdownPath)
- intake_review: $(Get-RelativeOrNone -Path $intakeReviewPath)
- intake_questions: $(Get-RelativeOrNone -Path $intakeQuestionsPath)
- env_manifest: $(Get-RelativeOrNone -Path $envManifestPath)
- env_example: $(Get-RelativeOrNone -Path $envExamplePath)
- sensitive_followups: $(Get-RelativeOrNone -Path $sensitiveReportPath)
- preflight: $(Get-RelativeOrNone -Path $preflightPath)
- latest_cycle: $(Get-RelativeOrNone -Path $latestReportPath)
- seed_summary: $(Get-RelativeOrNone -Path $latestSeedSummary)
- seed_resume: $(Get-RelativeOrNone -Path $seedResumeReportPath)
- seed_resume_json: $(Get-RelativeOrNone -Path $seedResumeJsonPath)
"@
Write-Utf8File -Path $statusMarkdownPath -Content $markdownText

$notifyScript = Join-Path $PSScriptRoot "send_harness_notification.ps1"
if (Test-Path -LiteralPath $notifyScript) {
    Invoke-HarnessPowerShellFile -FilePath $notifyScript -Arguments @("-StatusFile", $statusJsonPath, "-Quiet") -AllowFailure | Out-Null
}

if ($Json) {
    Write-Output $jsonText
} elseif (-not $Quiet) {
    Write-Output "status: $overallStatus"
    Write-Output "phase: $phase"
    Write-Output "user_action_required: $userActionRequired"
    if ($nextActions.Count -gt 0) {
        Write-Output "next_action:"
        foreach ($action in $nextActions) {
            Write-Output ("- " + $action)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($nextCommand)) {
        Write-Output "next_command: $nextCommand"
    }
    Write-Output "status_report: $statusMarkdownPath"
    Write-Output "status_json: $statusJsonPath"
}
