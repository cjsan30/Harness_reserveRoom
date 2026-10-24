param(
    [string]$IntakeFile = "docs/project_intake.md",
    [switch]$CreateTemplate,
    [switch]$Force,
    [switch]$RunPreflight,
    [switch]$RunSeedDryRun,
    [switch]$SkipSeedPlan,
    [switch]$AllowDeferredClarifications,
    [switch]$SkipIntakeReview
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
. (Join-Path $PSScriptRoot "intake_safety.ps1")

$rootDir = Get-HarnessRoot -ScriptDirectory $PSScriptRoot
$templatePath = Resolve-HarnessEnginePath -RootDir $rootDir -ProjectPath "harness/docs/project_intake.template.md" -Label "project intake template"
$intakePath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath $IntakeFile -Label "project intake file"

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

function ConvertTo-IntakeToken {
    param([string]$Value)

    $token = $Value.ToLowerInvariant() -replace "[^a-z0-9_-]", "-"
    $token = $token -replace "-{2,}", "-"
    $token = $token.Trim("-")
    if ([string]::IsNullOrWhiteSpace($token)) {
        return "intake"
    }

    return $token
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

function Set-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    } else {
        $Object.$Name = $Value
    }
}

if ($CreateTemplate -or -not (Test-Path -LiteralPath $intakePath)) {
    if ((Test-Path -LiteralPath $intakePath) -and -not $Force) {
        throw "intake file already exists; use -Force to overwrite: $IntakeFile"
    }

    $templateContent = Get-Content -Raw -LiteralPath $templatePath
    Write-Utf8File -Path $intakePath -Content $templateContent
    Write-Output "wrote intake template: $intakePath"
    if ($CreateTemplate -or -not $Force) {
        Write-Output "fill the intake file, then rerun start_from_intake.ps1"
        exit 0
    }
}

$lines = @(ConvertTo-SafeHarnessIntake -Lines @(Get-Content -Encoding UTF8 -LiteralPath $intakePath))
Assert-HarnessIntakeHasNoCredentials -Lines $lines

if (-not $SkipIntakeReview) {
    $reviewArgs = @("-IntakeFile", $IntakeFile)
    if ($AllowDeferredClarifications) {
        $reviewArgs += "-AllowDeferredClarifications"
    }
    if (-not $SkipSeedPlan) {
        $reviewArgs += "-RequireSeedPlan"
    }

    $reviewResult = Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot "review_project_intake.ps1") -Arguments $reviewArgs -AllowFailure
    if (-not [string]::IsNullOrWhiteSpace($reviewResult.Output)) {
        Write-Output $reviewResult.Output
    }
    if (-not $reviewResult.Success) {
        Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot "get_harness_status.ps1") -Arguments @("-Quiet") -AllowFailure | Out-Null
        exit $reviewResult.ExitCode
    }
}

$projectName = Get-MarkdownValue -Content $lines -Key "project_name"
$summary = Get-MarkdownValue -Content $lines -Key "summary"
$language = Get-MarkdownValue -Content $lines -Key "language"
$runtime = Get-MarkdownValue -Content $lines -Key "runtime"
$framework = Get-MarkdownValue -Content $lines -Key "framework"
$ide = Get-MarkdownValue -Content $lines -Key "ide"
$applicationType = Get-MarkdownValue -Content $lines -Key "application_type"

if (Test-IntakeScalarUnset -Value $projectName) {
    $projectName = Split-Path -Leaf $rootDir
}

$requirementsText = Get-IntakeSectionText -Lines $lines -SectionName "Requirements"
$successCriteriaText = Get-IntakeSectionText -Lines $lines -SectionName "Success Criteria"
$constraintsText = Get-IntakeSectionText -Lines $lines -SectionName "Constraints"
$assumptionsText = Get-IntakeSectionText -Lines $lines -SectionName "Assumptions"
$preparedDataText = Get-IntakeSectionText -Lines $lines -SectionName "Prepared Data"
$externalDependenciesText = Get-IntakeSectionText -Lines $lines -SectionName "External Dependencies"
$secretsText = Get-IntakeSectionText -Lines $lines -SectionName "Secrets And Access"
$sourceLinksText = Get-IntakeSectionText -Lines $lines -SectionName "Source Links"

$requirementsParts = New-Object System.Collections.Generic.List[string]
if (-not (Test-IntakePlaceholder -Value $summary)) {
    $requirementsParts.Add("# Summary`n`n$summary") | Out-Null
}
if (-not (Test-IntakePlaceholder -Value $requirementsText)) {
    $requirementsParts.Add("# Requirements`n`n$requirementsText") | Out-Null
}
if (-not (Test-IntakePlaceholder -Value $successCriteriaText)) {
    $requirementsParts.Add("# Success Criteria`n`n$successCriteriaText") | Out-Null
}
if (-not (Test-IntakePlaceholder -Value $constraintsText)) {
    $requirementsParts.Add("# Constraints`n`n$constraintsText") | Out-Null
}
if (-not (Test-IntakePlaceholder -Value $assumptionsText)) {
    $requirementsParts.Add("# Assumptions`n`n$assumptionsText") | Out-Null
}
if (-not (Test-IntakePlaceholder -Value $preparedDataText)) {
    $requirementsParts.Add("# Prepared Data`n`n$preparedDataText") | Out-Null
}
if (-not (Test-IntakePlaceholder -Value $externalDependenciesText)) {
    $requirementsParts.Add("# External Dependencies`n`n$externalDependenciesText") | Out-Null
}
if (-not (Test-IntakePlaceholder -Value $secretsText)) {
    $requirementsParts.Add("# Secrets And Access`n`n$secretsText") | Out-Null
}

$requirements = ($requirementsParts -join ([Environment]::NewLine + [Environment]::NewLine)).Trim()
if ([string]::IsNullOrWhiteSpace($requirements)) {
    throw "intake file must include a non-empty Requirements section or summary"
}

$initScript = Join-Path $PSScriptRoot "init_project_adapter.ps1"
$initArgs = @(
    "-ProjectName", $projectName,
    "-Requirements", $requirements
)
if (-not (Test-IntakeScalarUnset -Value $language)) {
    $initArgs += @("-Language", $language)
}
if (-not (Test-IntakeScalarUnset -Value $runtime)) {
    $initArgs += @("-Runtime", $runtime)
}
if (-not (Test-IntakeScalarUnset -Value $framework)) {
    $initArgs += @("-Framework", $framework)
}
if (-not (Test-IntakeScalarUnset -Value $ide)) {
    $initArgs += @("-Ide", $ide)
}
if (-not (Test-IntakeScalarUnset -Value $applicationType)) {
    $initArgs += @("-ApplicationType", $applicationType)
}
if ($Force) {
    $initArgs += "-Force"
}
$initResult = Invoke-HarnessPowerShellFile -FilePath $initScript -Arguments $initArgs -AllowFailure
if (-not [string]::IsNullOrWhiteSpace($initResult.Output)) {
    Write-Output $initResult.Output
}
if (-not $initResult.Success) {
    exit $initResult.ExitCode
}

$profilePath = Get-ProjectProfilePath -RootDir $rootDir
$profile = Get-ProjectProfile -RootDir $rootDir
$commands = Get-ProjectObjectProperty -Object $profile -Name "commands"
$commandMap = @{
    build = Get-MarkdownValue -Content $lines -Key "build_command"
    unit = Get-MarkdownValue -Content $lines -Key "unit_command"
    integration = Get-MarkdownValue -Content $lines -Key "integration_command"
    benchmark_smoke = Get-MarkdownValue -Content $lines -Key "benchmark_smoke_command"
    release = Get-MarkdownValue -Content $lines -Key "release_command"
}

$profileChanged = $false
foreach ($entry in $commandMap.GetEnumerator()) {
    if (-not (Test-IntakePlaceholder -Value $entry.Value)) {
        Set-ObjectPropertyValue -Object $commands -Name $entry.Key -Value $entry.Value.Trim()
        $profileChanged = $true
    }
}

if (-not (Test-IntakePlaceholder -Value $summary)) {
    $profile.project.summary = $summary.Trim()
    $profileChanged = $true
}

if (-not (Test-IntakePlaceholder -Value $successCriteriaText)) {
    $criteria = @($successCriteriaText -split "\r?\n" |
        ForEach-Object { ($_ -replace "^[\s*-]+", "").Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($criteria.Count -gt 0) {
        $profile.requirements.success_criteria = @($criteria)
        $profileChanged = $true
    }
}

if ($profileChanged) {
    Write-Utf8File -Path $profilePath -Content ($profile | ConvertTo-Json -Depth 20)
    Clear-ProjectProfileCache -RootDir $rootDir
    Write-Output "updated profile from intake: $profilePath"

    $profileDocsResult = Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot "generate_profile_docs.ps1") -AllowFailure
    if (-not [string]::IsNullOrWhiteSpace($profileDocsResult.Output)) {
        Write-Output $profileDocsResult.Output
    }
    if (-not $profileDocsResult.Success) {
        exit $profileDocsResult.ExitCode
    }
}

$requirementsPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath "docs/requirements.md" -Label "requirements doc"
if ($Force -or -not (Test-Path -LiteralPath $requirementsPath)) {
    Write-Utf8File -Path $requirementsPath -Content $requirements
    Write-Output "updated requirements doc: $requirementsPath"
}

$sourceLinksPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath "docs/requirements_raw_links.md" -Label "source links doc"
if (-not (Test-IntakePlaceholder -Value $sourceLinksText) -and ($Force -or -not (Test-Path -LiteralPath $sourceLinksPath))) {
    Write-Utf8File -Path $sourceLinksPath -Content ("# Requirement Sources`n`n" + $sourceLinksText.Trim())
    Write-Output "updated source links doc: $sourceLinksPath"
}

$envManifestResult = Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot "generate_env_manifest.ps1") -Arguments @("-IntakeFile", $IntakeFile) -AllowFailure
if (-not [string]::IsNullOrWhiteSpace($envManifestResult.Output)) {
    Write-Output $envManifestResult.Output
}
if (-not $envManifestResult.Success) {
    exit $envManifestResult.ExitCode
}

if ($RunPreflight) {
    $hooksResult = Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot "install_git_hooks.ps1") -AllowFailure
    if (-not [string]::IsNullOrWhiteSpace($hooksResult.Output)) {
        Write-Output $hooksResult.Output
    }
    if (-not $hooksResult.Success) {
        exit $hooksResult.ExitCode
    }

    $preflightResult = Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot "run_harness_preflight.ps1") -AllowFailure
    if (-not [string]::IsNullOrWhiteSpace($preflightResult.Output)) {
        Write-Output $preflightResult.Output
    }
    if (-not $preflightResult.Success) {
        exit $preflightResult.ExitCode
    }
}

$seedPlanPath = ""
if (-not $SkipSeedPlan) {
    $seedBlocks = @(Get-IntakeBlocks -Lines $lines -Header "## Seed Assignment")
    $validSeedBlocks = New-Object System.Collections.Generic.List[object]
    foreach ($block in $seedBlocks) {
        $owner = Get-MarkdownValue -Content $block -Key "owner"
        $title = Get-MarkdownValue -Content $block -Key "title"
        $task = Get-IntakeSectionText -Lines $block -SectionName "Task" -Level 3
        if ((Test-IntakePlaceholder -Value $owner) -and (Test-IntakePlaceholder -Value $title) -and (Test-IntakePlaceholder -Value $task)) {
            continue
        }

        if (Test-IntakePlaceholder -Value $owner) {
            throw "seed assignment is missing owner"
        }
        if (Test-IntakePlaceholder -Value $title) {
            throw "seed assignment for $owner is missing title"
        }
        if (Test-IntakePlaceholder -Value $task) {
            throw "seed assignment '$title' is missing Task text"
        }

        $validSeedBlocks.Add([pscustomobject]@{
            Owner = $owner.Trim()
            Title = $title.Trim()
            WorkArea = Get-MarkdownValue -Content $block -Key "work_area"
            Validation = Get-MarkdownValue -Content $block -Key "validation"
            Task = $task.Trim()
            Acceptance = (Get-IntakeSectionText -Lines $block -SectionName "Acceptance" -Level 3).Trim()
            Notes = (Get-IntakeSectionText -Lines $block -SectionName "Notes" -Level 3).Trim()
        }) | Out-Null
    }

    if ($validSeedBlocks.Count -gt 0) {
        $seedPlansDir = Get-HarnessConfiguredPath -RootDir $rootDir -Name "seed_plans" -FallbackRelativePath "harness/reports/seed_plans"
        Ensure-HarnessDirectory -Path $seedPlansDir
        $planId = Get-MarkdownValue -Content $lines -Key "plan_id"
        if (Test-IntakePlaceholder -Value $planId) {
            $planId = ConvertTo-IntakeToken -Value ($projectName + "-seed")
        } else {
            $planId = ConvertTo-IntakeToken -Value $planId
        }
        $dispatchMode = Get-MarkdownValue -Content $lines -Key "dispatch_mode"
        if (Test-IntakePlaceholder -Value $dispatchMode) {
            $dispatchMode = "serial"
        }

        $assignmentSections = New-Object System.Collections.Generic.List[string]
        foreach ($seed in $validSeedBlocks) {
            $workAreaLine = if (Test-IntakePlaceholder -Value $seed.WorkArea) { "" } else { $seed.WorkArea.Trim() }
            $validationLine = if (Test-IntakePlaceholder -Value $seed.Validation) { "" } else { $seed.Validation.Trim() }
            $acceptanceText = if (Test-IntakePlaceholder -Value $seed.Acceptance) { "- acceptance not specified" } else { $seed.Acceptance }
            $notesText = if (Test-IntakePlaceholder -Value $seed.Notes) { "none" } else { $seed.Notes }
            $assignmentSections.Add(@"
## Assignment

- owner: $($seed.Owner)
- title: $($seed.Title)
- work_area: $workAreaLine
- validation: $validationLine

### Task

$($seed.Task)

### Acceptance

$acceptanceText

### Notes

$notesText
"@) | Out-Null
        }

        $seedPlan = @"
# Assignment Seed Plan

## Meta

- plan_id: $planId
- summary: seed plan generated from $IntakeFile
- dispatch_mode: $dispatchMode

$($assignmentSections -join ([Environment]::NewLine + [Environment]::NewLine))
"@
        $seedPlanPath = Join-Path $seedPlansDir ($planId + ".md")
        Write-Utf8File -Path $seedPlanPath -Content $seedPlan
        Write-Output "generated seed plan: $seedPlanPath"
    }
}

if ($RunSeedDryRun -and -not [string]::IsNullOrWhiteSpace($seedPlanPath)) {
    $relativeSeedPlan = Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $seedPlanPath
    $seedResult = Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot "run_seed_handoff.ps1") -Arguments @("-DryRun", "-SkipAutoAdvanceGit", "-PlanFile", $relativeSeedPlan) -AllowFailure
    if (-not [string]::IsNullOrWhiteSpace($seedResult.Output)) {
        Write-Output $seedResult.Output
    }
    if (-not $seedResult.Success) {
        exit $seedResult.ExitCode
    }
}

Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot "get_harness_status.ps1") -Arguments @("-Quiet") -AllowFailure | Out-Null
Write-Output "intake_start: complete"
