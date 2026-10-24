param(
    [string]$IntakeFile = "docs/project_intake.md",
    [switch]$AllowDeferredClarifications,
    [switch]$RequireSeedPlan
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
. (Join-Path $PSScriptRoot "intake_safety.ps1")

$rootDir = Get-HarnessRoot -ScriptDirectory $PSScriptRoot
$intakePath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath $IntakeFile -Label "project intake file"
$reportPath = Resolve-HarnessEnginePath -RootDir $rootDir -ProjectPath "harness/reports/intake_review_report.md" -Label "intake review report"
$questionsPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath "docs/project_intake_questions.md" -Label "intake questions"

function Get-IntakeSectionText {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines,
        [Parameter(Mandatory = $true)]
        [string]$SectionName,
        [int]$Level = 2
    )

    $header = ("#" * $Level) + " " + $SectionName
    $startIndex = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -eq $header) {
            $startIndex = $i + 1
            break
        }
    }

    if ($startIndex -lt 0 -or $startIndex -ge $Lines.Count) {
        return ""
    }

    $endIndex = $Lines.Count
    for ($i = $startIndex; $i -lt $Lines.Count; $i++) {
        $trimmed = $Lines[$i].Trim()
        if ($trimmed -match "^#{1,$Level} ") {
            $endIndex = $i
            break
        }
    }

    if ($endIndex -le $startIndex) {
        return ""
    }

    return (@($Lines[$startIndex..($endIndex - 1)]) -join [Environment]::NewLine).Trim()
}

function Get-IntakeBlocks {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines,
        [Parameter(Mandatory = $true)]
        [string]$Header
    )

    $blocks = @()
    $current = @()
    $inside = $false
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq $Header) {
            if ($inside) {
                $blocks += ,@($current)
                $current = @()
            }
            $inside = $true
            continue
        }

        if ($inside -and $trimmed.StartsWith("## ") -and $trimmed -ne $Header) {
            $blocks += ,@($current)
            $current = @()
            $inside = $false
            continue
        }

        if ($inside) {
            $current += $line
        }
    }

    if ($inside) {
        $blocks += ,@($current)
    }

    return @($blocks)
}

function Test-IntakePlaceholder {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $true
    }

    $trimmed = $Value.Trim()
    $normalized = ($trimmed -replace "^[\s>*-]+", "").Trim()
    return ($normalized -eq "none" -or
        $normalized -eq "no known constraints" -or
        $normalized -eq "observable pass condition" -or
        $normalized.StartsWith("<") -or
        $trimmed.StartsWith("Write a concrete task") -or
        $trimmed.StartsWith("Describe what must be built") -or
        $trimmed.StartsWith("Leave command values blank") -or
        $trimmed.StartsWith("Add one or more"))
}

function Test-IntakeScalarUnset {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $true
    }

    $trimmed = $Value.Trim()
    return ($trimmed.StartsWith("<") -or
        $trimmed.StartsWith("Write a concrete task") -or
        $trimmed.StartsWith("Describe what must be built") -or
        $trimmed.StartsWith("Leave command values blank") -or
        $trimmed.StartsWith("Add one or more"))
}

function Add-ReviewItem {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$List,
        [Parameter(Mandatory = $true)]
        [string]$Area,
        [Parameter(Mandatory = $true)]
        [string]$Question,
        [string]$Reason = ""
    )

    $List.Add([pscustomobject]@{
        Area = $Area
        Question = $Question
        Reason = $Reason
    }) | Out-Null
}

function Format-ReviewItems {
    param(
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Items
    )

    if ($Items.Count -eq 0) {
        return "- none"
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $index = 0
    foreach ($item in $Items) {
        $index += 1
        $lines.Add(("- Q{0}: {1}" -f $index, $item.Question)) | Out-Null
        $lines.Add(("  - area: {0}" -f $item.Area)) | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($item.Reason)) {
            $lines.Add(("  - reason: {0}" -f $item.Reason)) | Out-Null
        }
    }

    return ($lines -join [Environment]::NewLine)
}

function Get-PatternHits {
    param(
        [string]$Text,
        [string[]]$Patterns
    )

    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $Patterns) {
        if ($Text -match $pattern) {
            $hits.Add($pattern) | Out-Null
        }
    }

    return @($hits)
}

function Test-GitHeadAvailable {
    try {
        $result = Invoke-HarnessProcess -Executable "git" -Arguments @("rev-parse", "--verify", "HEAD") -WorkingDirectory $rootDir -AllowFailure
        return $result.Success
    } catch {
        return $false
    }
}

if (-not (Test-Path -LiteralPath $intakePath)) {
    throw "intake file not found: $IntakeFile"
}

$lines = @(ConvertTo-SafeHarnessIntake -Lines @(Get-Content -Encoding UTF8 -LiteralPath $intakePath))
Assert-HarnessIntakeHasNoCredentials -Lines $lines
$projectName = Get-MarkdownValue -Content $lines -Key "project_name"
$summary = Get-MarkdownValue -Content $lines -Key "summary"
$language = Get-MarkdownValue -Content $lines -Key "language"
$runtime = Get-MarkdownValue -Content $lines -Key "runtime"
$framework = Get-MarkdownValue -Content $lines -Key "framework"
$clarificationMode = Get-MarkdownValue -Content $lines -Key "clarification_mode"
$requirementsText = Get-IntakeSectionText -Lines $lines -SectionName "Requirements"
$successCriteriaText = Get-IntakeSectionText -Lines $lines -SectionName "Success Criteria"
$constraintsText = Get-IntakeSectionText -Lines $lines -SectionName "Constraints"
$assumptionsText = Get-IntakeSectionText -Lines $lines -SectionName "Assumptions"
$preparedDataText = Get-IntakeSectionText -Lines $lines -SectionName "Prepared Data"
$externalDependenciesText = Get-IntakeSectionText -Lines $lines -SectionName "External Dependencies"
$secretsText = Get-IntakeSectionText -Lines $lines -SectionName "Secrets And Access"
$fullProjectText = @($summary, $requirementsText, $successCriteriaText, $constraintsText, $assumptionsText, $preparedDataText, $externalDependenciesText, $secretsText) -join [Environment]::NewLine
$deferAllowed = $AllowDeferredClarifications -or (@("defer_allowed", "ask_later", "start_then_ask") -contains $clarificationMode.Trim().ToLowerInvariant())

$blockers = New-Object System.Collections.Generic.List[object]
$questions = New-Object System.Collections.Generic.List[object]
$externalQuestions = New-Object System.Collections.Generic.List[object]
$failurePrevention = New-Object System.Collections.Generic.List[object]
$sensitiveFollowups = New-Object System.Collections.Generic.List[object]

if (Test-IntakePlaceholder -Value $summary) {
    Add-ReviewItem -List $blockers -Area "Project" -Question "Add a one-paragraph project summary before starting." -Reason "summary is required for owner prompts"
}

if (Test-IntakePlaceholder -Value $requirementsText) {
    Add-ReviewItem -List $blockers -Area "Requirements" -Question "Add concrete requirements before starting." -Reason "workers need enough product scope to decide code and tests"
} elseif ($requirementsText.Length -lt 80) {
    Add-ReviewItem -List $questions -Area "Requirements" -Question "Expand the requirements with concrete user flows, data, or behavior." -Reason "requirements are very short"
}

$criteriaLines = @($successCriteriaText -split "\r?\n" |
    ForEach-Object { ($_ -replace "^[\s*-]+", "").Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not (Test-IntakePlaceholder -Value $_) })
if ($criteriaLines.Count -lt 2) {
    Add-ReviewItem -List $questions -Area "Success Criteria" -Question "Add at least two observable success criteria beyond generic build/test completion." -Reason "success criteria are too thin for handoff review"
}

if ((Test-IntakeScalarUnset -Value $language) -and (Test-IntakeScalarUnset -Value $runtime) -and (Test-IntakeScalarUnset -Value $framework)) {
    Add-ReviewItem -List $questions -Area "Project" -Question "Specify the intended language/runtime/framework or confirm the harness should infer them." -Reason "stack inference may choose the wrong preset"
}

$commandKeys = @("build_command", "unit_command", "integration_command")
foreach ($commandKey in $commandKeys) {
    $commandValue = Get-MarkdownValue -Content $lines -Key $commandKey
    if ((Test-IntakePlaceholder -Value $commandValue) -and (Test-IntakeScalarUnset -Value $language) -and (Test-IntakeScalarUnset -Value $framework)) {
        Add-ReviewItem -List $failurePrevention -Area "Commands" -Question "Provide $commandKey or fill language/framework so the harness can select a preset." -Reason "missing validation commands increase worker retry risk"
    }
}

$vagueTerms = @(
    "\bsimple\b",
    "\bnice\b",
    "\bfast\b",
    "\bperformant\b",
    "\bscalable\b",
    "\bsecure\b",
    "\buser[- ]friendly\b",
    "\betc\.?\b",
    "\bproper\b",
    "\bappropriate\b",
    "\bclean\b",
    "\beasy\b"
)
$vagueHits = @(Get-PatternHits -Text $fullProjectText.ToLowerInvariant() -Patterns $vagueTerms)
if ($vagueHits.Count -gt 0 -and (Test-IntakePlaceholder -Value $assumptionsText)) {
    Add-ReviewItem -List $questions -Area "Assumptions" -Question "Clarify vague terms such as simple/nice/fast/secure, or write explicit assumptions that workers may use." -Reason "vague quality targets often cause mid-development questions"
}

$externalPatterns = @(
    @{ Name = "auth"; Pattern = "\b(auth|login|oauth|jwt|session)\b"; Question = "For auth/login, specify provider, session model, roles, and whether mock/local auth is acceptable." },
    @{ Name = "payments"; Pattern = "\b(payment|billing|stripe|checkout)\b"; Question = "For payments/billing, specify provider, sandbox mode, required env vars, and whether payment can be mocked." },
    @{ Name = "email"; Pattern = "\b(email|smtp|sendgrid|mailgun)\b"; Question = "For email, specify provider, sending mode, required env vars, and local fallback behavior." },
    @{ Name = "database"; Pattern = "\b(database|postgres|mysql|supabase|firebase|redis|mongodb)\b"; Question = "For external data stores, specify local vs remote setup, migration command, and required connection env vars." },
    @{ Name = "external-api"; Pattern = "\b(openai|llm|api key|external api|webhook)\b"; Question = "For external APIs, specify provider, required env vars, rate/error behavior, and mock strategy." }
)
foreach ($entry in $externalPatterns) {
    if ($fullProjectText.ToLowerInvariant() -match $entry.Pattern) {
        if (Test-IntakePlaceholder -Value $externalDependenciesText) {
            Add-ReviewItem -List $externalQuestions -Area "External Dependencies" -Question $entry.Question -Reason ("detected dependency keyword: " + $entry.Name)
        }
        if (Test-IntakePlaceholder -Value $preparedDataText) {
            Add-ReviewItem -List $externalQuestions -Area "Prepared Data" -Question "Add safe mock/sample data, local config names, or a clear fallback strategy for this dependency." -Reason ("workers should not need live credentials to make progress: " + $entry.Name)
        }
        if (Test-IntakePlaceholder -Value $secretsText) {
            Add-ReviewItem -List $sensitiveFollowups -Area "Secrets And Access" -Question "Record required secret or environment variable names later; do not paste real token values into intake." -Reason ("sensitive value may be needed outside harness automation: " + $entry.Name)
        }
    }
}

$seedBlocks = @(Get-IntakeBlocks -Lines $lines -Header "## Seed Assignment")
$validSeedCount = 0
foreach ($block in $seedBlocks) {
    $owner = Get-MarkdownValue -Content $block -Key "owner"
    $title = Get-MarkdownValue -Content $block -Key "title"
    $validation = Get-MarkdownValue -Content $block -Key "validation"
    $task = Get-IntakeSectionText -Lines $block -SectionName "Task" -Level 3
    $acceptance = Get-IntakeSectionText -Lines $block -SectionName "Acceptance" -Level 3
    $allPlaceholder = (Test-IntakePlaceholder -Value $owner) -and (Test-IntakePlaceholder -Value $title) -and (Test-IntakePlaceholder -Value $task)
    if ($allPlaceholder) {
        continue
    }

    $validSeedCount += 1
    if (Test-IntakePlaceholder -Value $owner) {
        Add-ReviewItem -List $failurePrevention -Area "Seed Assignment" -Question "Fill owner for seed assignment $validSeedCount." -Reason "unknown owner cannot be dispatched"
    }
    if (Test-IntakePlaceholder -Value $title) {
        Add-ReviewItem -List $failurePrevention -Area "Seed Assignment" -Question "Fill title for seed assignment $validSeedCount." -Reason "assignment id cannot be derived safely"
    }
    if (Test-IntakePlaceholder -Value $task) {
        Add-ReviewItem -List $failurePrevention -Area "Seed Assignment" -Question "Fill a concrete Task section for seed assignment $validSeedCount." -Reason "worker prompt would not be actionable"
    }
    if (Test-IntakePlaceholder -Value $acceptance) {
        Add-ReviewItem -List $failurePrevention -Area "Seed Assignment" -Question "Fill observable Acceptance criteria for seed assignment $validSeedCount." -Reason "completion cannot be reviewed reliably"
    }
    if (Test-IntakePlaceholder -Value $validation) {
        Add-ReviewItem -List $failurePrevention -Area "Seed Assignment" -Question "Fill validation command for seed assignment $validSeedCount or rely on a known owner default." -Reason "missing validation increases retry risk"
    }
}

if ($RequireSeedPlan -and $validSeedCount -eq 0) {
    Add-ReviewItem -List $failurePrevention -Area "Seed Plan" -Question "Add at least one filled Seed Assignment or rerun start_from_intake.ps1 with -SkipSeedPlan." -Reason "no initial development work would be dispatched"
}

$gitHeadExists = Test-GitHeadAvailable
$baselineStatus = "not_required_yet"
$baselineNextAction = "none"
if ($gitHeadExists) {
    $baselineStatus = "ready"
} elseif ($validSeedCount -gt 0 -or $RequireSeedPlan) {
    $baselineStatus = "needed_before_live"
    $baselineNextAction = "after intake start and seed dry-run pass, create the first Git commit before live seed handoff"
}

$baselineReadiness = @"
- git_head_exists: $(if ($gitHeadExists) { "true" } else { "false" })
- live_seed_assignments: $validSeedCount
- live_execution_baseline_status: $baselineStatus
- next_action: $baselineNextAction
- note: seed dry-run can run before the first commit; live worker dispatch cannot
"@

$openQuestionCount = $questions.Count + $externalQuestions.Count + $failurePrevention.Count
$status = "pass"
if ($blockers.Count -gt 0) {
    $status = "blocked"
} elseif ($openQuestionCount -gt 0 -and $deferAllowed) {
    $status = "deferred"
} elseif ($openQuestionCount -gt 0) {
    $status = "needs_input"
}

$questionsContent = @"
# Project Intake Questions

## Summary

- status: $status
- intake_file: $IntakeFile
- defer_allowed: $(if ($deferAllowed) { "true" } else { "false" })

## Git Baseline Readiness

$baselineReadiness

## Required Fixes

$(Format-ReviewItems -Items $blockers)

## Clarification Questions

$(Format-ReviewItems -Items $questions)

## External Access Questions

$(Format-ReviewItems -Items $externalQuestions)

## Failure Prevention Questions

$(Format-ReviewItems -Items $failurePrevention)

## Sensitive Follow-Ups

$(Format-ReviewItems -Items $sensitiveFollowups)

## How To Resolve

- Update `docs/project_intake.md` with the answers, especially Requirements, Success Criteria, Assumptions, Prepared Data, External Dependencies, and Seed Assignment sections.
- Do not paste real private tokens, passwords, or personal credentials into intake. Track secret names and provide real values later through the project environment.
- To start anyway and let workers ask later, set `clarification_mode: defer_allowed` in `docs/project_intake.md` or rerun with `-AllowDeferredClarifications`.
"@
Write-Utf8File -Path $questionsPath -Content $questionsContent

$reportContent = @"
# Intake Review Report

## Summary

- status: $status
- intake_file: $IntakeFile
- questions_file: $(Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $questionsPath)
- defer_allowed: $(if ($deferAllowed) { "true" } else { "false" })
- blocker_count: $($blockers.Count)
- open_question_count: $openQuestionCount
- sensitive_followup_count: $($sensitiveFollowups.Count)
- git_head_exists: $(if ($gitHeadExists) { "true" } else { "false" })
- live_execution_baseline_status: $baselineStatus
- recorded_at: $((Get-Date).ToString("o"))

## Git Baseline Readiness

$baselineReadiness

## Required Fixes

$(Format-ReviewItems -Items $blockers)

## Clarification Questions

$(Format-ReviewItems -Items $questions)

## External Access Questions

$(Format-ReviewItems -Items $externalQuestions)

## Failure Prevention Questions

$(Format-ReviewItems -Items $failurePrevention)

## Sensitive Follow-Ups

$(Format-ReviewItems -Items $sensitiveFollowups)
"@
Write-Utf8File -Path $reportPath -Content $reportContent

Write-Output "intake review status: $status"
Write-Output "intake review report: $reportPath"
Write-Output "intake questions: $questionsPath"
Write-Output "git baseline status: $baselineStatus"

$statusScript = Join-Path $PSScriptRoot "get_harness_status.ps1"
if (Test-Path -LiteralPath $statusScript) {
    Invoke-HarnessPowerShellFile -FilePath $statusScript -Arguments @("-Quiet") -AllowFailure | Out-Null
}

if ($status -eq "blocked") {
    exit 2
}
if ($status -eq "needs_input") {
    exit 3
}
