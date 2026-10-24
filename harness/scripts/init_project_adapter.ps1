param(
    [string]$ProjectName = "",
    [string]$Requirements = "",
    [string]$RequirementsFile = "",
    [string]$Language = "",
    [string]$Runtime = "",
    [string]$Framework = "",
    [string]$Ide = "",
    [string]$ApplicationType = "",
    [switch]$Interactive,
    [switch]$ListPresets,
    [switch]$Force,
    [switch]$RunPreflight
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")

$rootDir = Get-HarnessRoot -ScriptDirectory $PSScriptRoot
$projectRoot = Resolve-HarnessEnginePath -RootDir $rootDir -ProjectPath "harness/project" -Label "harness.project"
$projectConfigs = Join-Path $projectRoot "configs"
$projectPrompts = Join-Path $projectRoot "prompts"
$templatePath = Resolve-HarnessEnginePath -RootDir $rootDir -ProjectPath "harness/configs/project_profile.template.json" -Label "profile template"
$profilePath = Join-Path $projectConfigs "project_profile.json"
$resolvedProjectName = $ProjectName
if ([string]::IsNullOrWhiteSpace($resolvedProjectName)) {
    $resolvedProjectName = Split-Path -Leaf $rootDir
}

function Normalize-ProfileKey {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    return $Value.Trim().ToLowerInvariant()
}

function Set-ProfileProperty {
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

function Get-RequirementsText {
    param(
        [string]$InlineRequirements,
        [string]$FilePath
    )

    if (-not [string]::IsNullOrWhiteSpace($InlineRequirements)) {
        return $InlineRequirements.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
        $resolvedPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath $FilePath -Label "RequirementsFile"
        if (-not (Test-Path -LiteralPath $resolvedPath)) {
            throw "requirements file not found: $FilePath"
        }
        return (Get-Content -Raw -LiteralPath $resolvedPath).Trim()
    }

    return ""
}

function Get-RequirementSummary {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return "replace-with-one-paragraph-product-summary"
    }

    $singleLine = (($Text -replace "\r?\n", " ") -replace "\s+", " ").Trim()
    if ($singleLine.Length -gt 180) {
        return $singleLine.Substring(0, 177) + "..."
    }

    return $singleLine
}

function Convert-RequirementsToCriteria {
    param([string]$Text)

    $criteria = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        foreach ($line in ($Text -split "\r?\n")) {
            $trimmed = ($line -replace "^[\s#>*-]+", "").Trim()
            if ($trimmed.Length -lt 8) {
                continue
            }
            $criteria.Add($trimmed) | Out-Null
            if ($criteria.Count -ge 5) {
                break
            }
        }
    }

    if ($criteria.Count -eq 0) {
        $criteria.Add("build command passes") | Out-Null
        $criteria.Add("unit command passes") | Out-Null
        $criteria.Add("integration command passes") | Out-Null
    }

    return @($criteria)
}

function Add-InferenceSignal {
    param(
        [System.Collections.Generic.List[object]]$Signals,
        [string]$LanguageName,
        [string]$FrameworkName,
        [string]$ApplicationKind,
        [int]$Score,
        [string]$Reason
    )

    $Signals.Add([pscustomobject]@{
        language = $LanguageName
        framework = $FrameworkName
        application_type = $ApplicationKind
        score = $Score
        reason = $Reason
    }) | Out-Null
}

function Get-InferredAdapterTarget {
    param([string]$Text)

    $signals = New-Object System.Collections.Generic.List[object]
    $normalized = Normalize-ProfileKey -Value $Text

    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return [pscustomobject]@{
            language = ""
            framework = ""
            application_type = ""
            confidence = "none"
            reason = "no requirements supplied"
        }
    }

    if ($normalized -match "\bnext(\.js)?\b|react|frontend|dashboard|spa|web app|ui\b") {
        Add-InferenceSignal -Signals $signals -LanguageName "typescript" -FrameworkName "next" -ApplicationKind "frontend" -Score 5 -Reason "frontend or Next/React requirement"
    }
    if ($normalized -match "\bvue\b|nuxt") {
        Add-InferenceSignal -Signals $signals -LanguageName "typescript" -FrameworkName "nuxt" -ApplicationKind "frontend" -Score 5 -Reason "Vue/Nuxt requirement"
    }
    if ($normalized -match "\bsvelte\b|sveltekit") {
        Add-InferenceSignal -Signals $signals -LanguageName "typescript" -FrameworkName "sveltekit" -ApplicationKind "frontend" -Score 5 -Reason "Svelte/SvelteKit requirement"
    }
    if ($normalized -match "\bapi\b|backend|server|rest|graphql|auth|database|db\b") {
        Add-InferenceSignal -Signals $signals -LanguageName "python" -FrameworkName "fastapi" -ApplicationKind "backend" -Score 3 -Reason "backend/API requirement"
    }
    if ($normalized -match "fastapi") {
        Add-InferenceSignal -Signals $signals -LanguageName "python" -FrameworkName "fastapi" -ApplicationKind "backend" -Score 6 -Reason "FastAPI explicitly mentioned"
    }
    if ($normalized -match "\bdjango\b") {
        Add-InferenceSignal -Signals $signals -LanguageName "python" -FrameworkName "django" -ApplicationKind "backend" -Score 6 -Reason "Django explicitly mentioned"
    }
    if ($normalized -match "\bflask\b") {
        Add-InferenceSignal -Signals $signals -LanguageName "python" -FrameworkName "flask" -ApplicationKind "backend" -Score 6 -Reason "Flask explicitly mentioned"
    }
    if ($normalized -match "\bexpress\b|node api|node\.js|nodejs") {
        Add-InferenceSignal -Signals $signals -LanguageName "typescript" -FrameworkName "express" -ApplicationKind "backend" -Score 6 -Reason "Node backend explicitly mentioned"
    }
    if ($normalized -match "\bspring\b|spring boot") {
        Add-InferenceSignal -Signals $signals -LanguageName "java" -FrameworkName "gradle" -ApplicationKind "backend" -Score 6 -Reason "Spring requirement"
    }
    if ($normalized -match "\bcli\b|command line|native|embedded|systems|parser|compiler|database engine|storage engine|b\+ tree|b-tree") {
        Add-InferenceSignal -Signals $signals -LanguageName "c11" -FrameworkName "none" -ApplicationKind "systems" -Score 4 -Reason "systems or CLI requirement"
    }
    if ($normalized -match "\brust\b|cargo") {
        Add-InferenceSignal -Signals $signals -LanguageName "rust" -FrameworkName "none" -ApplicationKind "systems" -Score 7 -Reason "Rust explicitly mentioned"
    }
    if ($normalized -match "\bgo\b|golang") {
        Add-InferenceSignal -Signals $signals -LanguageName "go" -FrameworkName "none" -ApplicationKind "backend" -Score 6 -Reason "Go explicitly mentioned"
    }
    if ($normalized -match "\.net|dotnet|c#|csharp") {
        Add-InferenceSignal -Signals $signals -LanguageName "dotnet" -FrameworkName "none" -ApplicationKind "backend" -Score 7 -Reason ".NET explicitly mentioned"
    }

    if ($signals.Count -eq 0) {
        return [pscustomobject]@{
            language = ""
            framework = ""
            application_type = ""
            confidence = "none"
            reason = "requirements do not mention a recognizable stack"
        }
    }

    $best = $signals | Sort-Object -Property score -Descending | Select-Object -First 1
    $confidence = "low"
    if ($best.score -ge 6) {
        $confidence = "high"
    } elseif ($best.score -ge 4) {
        $confidence = "medium"
    }

    return [pscustomobject]@{
        language = $best.language
        framework = $best.framework
        application_type = $best.application_type
        confidence = $confidence
        reason = $best.reason
    }
}

function Read-AdapterChoice {
    param(
        [string]$Prompt,
        [string]$DefaultValue
    )

    $suffix = ""
    if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
        $suffix = " [$DefaultValue]"
    }

    $value = Read-Host ($Prompt + $suffix)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }

    return $value.Trim()
}

function New-OwnerProfile {
    param(
        [string[]]$Read,
        [string]$WorkArea,
        [string]$Validation,
        [string[]]$FailureScope
    )

    return [pscustomobject]@{
        read = @($Read)
        work_area = $WorkArea
        validation = $Validation
        failure_scope = @($FailureScope)
    }
}

function New-StandardOwners {
    param(
        [string]$Kind,
        [string]$BuildCommand,
        [string]$UnitCommand,
        [string]$IntegrationCommand,
        [string]$BenchmarkCommand
    )

    $commonDocs = @(
        "AGENT.md",
        "docs/requirements.md",
        "docs/requirements_raw_links.md",
        "docs/env_manifest.md",
        "docs/subagent_plan.md",
        "docs/subagent_first_prompts.md",
        "harness/AGENT.md"
    )

    $owners = [ordered]@{}
    $normalizedKind = Normalize-ProfileKey -Value $Kind
    switch ($normalizedKind) {
        "frontend" {
            $owners["agent-runtime"] = New-OwnerProfile -Read $commonDocs -WorkArea "src/app" -Validation $IntegrationCommand -FailureScope @("app shell", "routing", "bootstrap")
            $owners["agent-ui"] = New-OwnerProfile -Read $commonDocs -WorkArea "src/components" -Validation $UnitCommand -FailureScope @("components", "layout", "interaction")
            $owners["agent-state"] = New-OwnerProfile -Read $commonDocs -WorkArea "src/state" -Validation $UnitCommand -FailureScope @("state", "client data flow", "hooks")
            $owners["agent-data"] = New-OwnerProfile -Read $commonDocs -WorkArea "src/lib" -Validation $IntegrationCommand -FailureScope @("api client", "schema", "data transformation")
        }
        "backend" {
            $owners["agent-runtime"] = New-OwnerProfile -Read $commonDocs -WorkArea "src" -Validation $IntegrationCommand -FailureScope @("entrypoint", "server startup", "configuration")
            $owners["agent-api"] = New-OwnerProfile -Read $commonDocs -WorkArea "src/api" -Validation $IntegrationCommand -FailureScope @("routes", "controllers", "request handling")
            $owners["agent-domain"] = New-OwnerProfile -Read $commonDocs -WorkArea "src/domain" -Validation $UnitCommand -FailureScope @("business rules", "services", "validation")
            $owners["agent-data"] = New-OwnerProfile -Read $commonDocs -WorkArea "src/data" -Validation $IntegrationCommand -FailureScope @("database", "repository", "persistence")
        }
        "systems" {
            $owners["agent-runtime"] = New-OwnerProfile -Read $commonDocs -WorkArea "src/runtime" -Validation $IntegrationCommand -FailureScope @("entrypoint", "cli", "bootstrap")
            $owners["agent-core"] = New-OwnerProfile -Read $commonDocs -WorkArea "src/core" -Validation $UnitCommand -FailureScope @("core logic", "algorithms", "data structures")
            $owners["agent-storage"] = New-OwnerProfile -Read $commonDocs -WorkArea "src/storage" -Validation $IntegrationCommand -FailureScope @("io", "persistence", "serialization")
            $owners["agent-interface"] = New-OwnerProfile -Read $commonDocs -WorkArea "include" -Validation $BuildCommand -FailureScope @("headers", "public contract", "module boundary")
        }
        default {
            $owners["agent-runtime"] = New-OwnerProfile -Read $commonDocs -WorkArea "src" -Validation $IntegrationCommand -FailureScope @("entrypoint", "runtime", "bootstrap")
            $owners["agent-core"] = New-OwnerProfile -Read $commonDocs -WorkArea "src" -Validation $UnitCommand -FailureScope @("core logic", "module behavior", "interfaces")
            $owners["agent-tests"] = New-OwnerProfile -Read $commonDocs -WorkArea "tests" -Validation $UnitCommand -FailureScope @("unit tests", "integration tests", "fixtures")
        }
    }

    if (-not $owners.Contains("agent-tests")) {
        $owners["agent-tests"] = New-OwnerProfile -Read $commonDocs -WorkArea "tests" -Validation $UnitCommand -FailureScope @("unit tests", "integration tests", "fixtures")
    }

    $owners["manager-main"] = New-OwnerProfile -Read @(
        "AGENT.md",
        "docs/requirements.md",
        "docs/requirements_raw_links.md",
        "docs/env_manifest.md",
        "docs/subagent_plan.md",
        "docs/subagent_first_prompts.md",
        "harness/AGENT.md",
        "harness/project/prompts/manager_main.md",
        "harness/project/prompts/manager_main_seed.md",
        "harness/configs/git_policy.md"
    ) -WorkArea "project-wide" -Validation $BuildCommand -FailureScope @("cross-module", "interface reconciliation", "integration ownership")

    $owners["manager-harness"] = New-OwnerProfile -Read @(
        "AGENT.md",
        "docs/requirements.md",
        "docs/requirements_raw_links.md",
        "docs/env_manifest.md",
        "docs/subagent_plan.md",
        "docs/subagent_first_prompts.md",
        "harness/AGENT.md",
        "harness/project/prompts/manager_harness.md",
        "harness/configs/git_policy.md",
        "harness/configs/retry_dispatch_policy.md"
    ) -WorkArea "harness" -Validation "pwsh -NoProfile -File harness/scripts/run_harness_cycle.ps1 -SkipRetryPrompt" -FailureScope @("tooling", "dispatch", "automation")

    $ownerObject = [pscustomobject]@{}
    foreach ($entry in $owners.GetEnumerator()) {
        Set-ProfileProperty -Object $ownerObject -Name $entry.Key -Value $entry.Value
    }

    return $ownerObject
}

function Get-AdapterPreset {
    param(
        [string]$LanguageName,
        [string]$FrameworkName
    )

    $languageKey = Normalize-ProfileKey -Value $LanguageName
    $frameworkKey = Normalize-ProfileKey -Value $FrameworkName
    $runtimeValue = ""
    $kind = "generic"
    $commands = [ordered]@{
        build = "make"
        unit = "make unit"
        integration = "make integration"
        benchmark_smoke = "make benchmark-smoke"
        release = "make release"
        full_cycle = "pwsh -NoProfile -File harness/scripts/run_harness_cycle.ps1"
    }

    switch -Regex ($languageKey) {
        "^(c|c11|c17|cpp|c\+\+)$" {
            $runtimeValue = "native executable"
            $kind = "systems"
            if ($frameworkKey -eq "cmake") {
                $commands.build = "cmake --build build"
                $commands.unit = "ctest --test-dir build"
                $commands.integration = "ctest --test-dir build"
                $commands.benchmark_smoke = "ctest --test-dir build -R smoke"
                $commands.release = "cmake --build build --config Release"
            }
            break
        }
        "^(node|nodejs|javascript|typescript|ts|js)$" {
            $runtimeValue = "Node.js"
            $kind = "frontend"
            $commands.build = "npm run build"
            $commands.unit = "npm test"
            $commands.integration = "npm run test:integration"
            $commands.benchmark_smoke = "npm run benchmark:smoke"
            $commands.release = "npm run build"
            if ($frameworkKey -in @("express", "fastify", "nestjs", "nest")) {
                $kind = "backend"
            }
            break
        }
        "^(python|py)$" {
            $runtimeValue = "Python"
            $kind = "backend"
            $commands.build = "python -m compileall ."
            $commands.unit = "python -m pytest tests/unit"
            $commands.integration = "python -m pytest tests/integration"
            $commands.benchmark_smoke = "python -m pytest tests -m smoke"
            $commands.release = "python -m build"
            break
        }
        "^(java|kotlin)$" {
            $runtimeValue = "JVM"
            $kind = "backend"
            if ($frameworkKey -eq "maven") {
                $commands.build = "mvn package"
                $commands.unit = "mvn test"
                $commands.integration = "mvn verify"
                $commands.benchmark_smoke = "mvn test -Dgroups=smoke"
                $commands.release = "mvn package"
            } else {
                $commands.build = "gradle build"
                $commands.unit = "gradle test"
                $commands.integration = "gradle check"
                $commands.benchmark_smoke = "gradle test --tests *Smoke*"
                $commands.release = "gradle assemble"
            }
            break
        }
        "^(csharp|c#|dotnet|\.net)$" {
            $runtimeValue = ".NET"
            $kind = "backend"
            $commands.build = "dotnet build"
            $commands.unit = "dotnet test"
            $commands.integration = "dotnet test"
            $commands.benchmark_smoke = "dotnet test --filter Smoke"
            $commands.release = "dotnet publish -c Release"
            break
        }
        "^(go|golang)$" {
            $runtimeValue = "Go"
            $kind = "backend"
            $commands.build = "go build ./..."
            $commands.unit = "go test ./..."
            $commands.integration = "go test ./..."
            $commands.benchmark_smoke = "go test ./... -run Smoke"
            $commands.release = "go build ./..."
            break
        }
        "^(rust|rs)$" {
            $runtimeValue = "Rust"
            $kind = "systems"
            $commands.build = "cargo build"
            $commands.unit = "cargo test"
            $commands.integration = "cargo test"
            $commands.benchmark_smoke = "cargo test smoke"
            $commands.release = "cargo build --release"
            break
        }
    }

    $commandObject = [pscustomobject]@{}
    foreach ($entry in $commands.GetEnumerator()) {
        Set-ProfileProperty -Object $commandObject -Name $entry.Key -Value $entry.Value
    }

    return [pscustomobject]@{
        kind = $kind
        runtime = $runtimeValue
        commands = $commandObject
        owners = New-StandardOwners -Kind $kind -BuildCommand $commands.build -UnitCommand $commands.unit -IntegrationCommand $commands.integration -BenchmarkCommand $commands.benchmark_smoke
    }
}

if ($ListPresets) {
    Write-Output "Supported adapter presets:"
    Write-Output "- C/C++: make by default, cmake when -Framework cmake"
    Write-Output "- Node/JavaScript/TypeScript: npm build/test defaults; backend owners for express/fastify/nestjs"
    Write-Output "- Python: compileall, pytest, python -m build"
    Write-Output "- Java/Kotlin: gradle by default, maven when -Framework maven"
    Write-Output "- .NET/C#: dotnet build/test/publish"
    Write-Output "- Go: go build/test"
    Write-Output "- Rust: cargo build/test"
    Write-Output ""
    Write-Output "Requirement inference examples:"
    Write-Output "- -RequirementsFile docs/product.md -Interactive"
    Write-Output "- -Requirements 'Build a Next.js dashboard with auth' -Force"
    exit 0
}

function Write-AdapterFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    if ((Test-Path -LiteralPath $Path) -and -not $Force) {
        Write-Output "kept existing: $(Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $Path)"
        return
    }

    if ([IO.Path]::GetFullPath($Path).StartsWith([IO.Path]::GetFullPath($projectPrompts) + [IO.Path]::DirectorySeparatorChar, (Get-HarnessPathComparison))) {
        $Content = Convert-HarnessLayoutText $rootDir $Content
    }
    Write-Utf8File -Path $Path -Content $Content
    Write-Output "wrote: $(Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $Path)"
}

function Write-SeedFileIfMissing {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    if (Test-Path -LiteralPath $Path) {
        Write-Output "kept existing: $(Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $Path)"
        return
    }

    Write-Utf8File -Path $Path -Content $Content
    Write-Output "wrote seed: $(Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $Path)"
}

if (-not (Test-Path -LiteralPath $templatePath)) {
    throw "missing profile template: $templatePath"
}

Ensure-HarnessDirectory -Path $projectConfigs
Ensure-HarnessDirectory -Path $projectPrompts

$requirementsText = Get-RequirementsText -InlineRequirements $Requirements -FilePath $RequirementsFile
$inferredTarget = Get-InferredAdapterTarget -Text $requirementsText

if ([string]::IsNullOrWhiteSpace($Language) -and $inferredTarget.confidence -in @("high", "medium")) {
    $Language = $inferredTarget.language
    Write-Output "inferred language: $Language ($($inferredTarget.reason), confidence: $($inferredTarget.confidence))"
}

if ([string]::IsNullOrWhiteSpace($Framework) -and $inferredTarget.confidence -in @("high", "medium")) {
    $Framework = $inferredTarget.framework
    Write-Output "inferred framework: $Framework"
}

if ([string]::IsNullOrWhiteSpace($ApplicationType) -and $inferredTarget.confidence -in @("high", "medium")) {
    $ApplicationType = $inferredTarget.application_type
    Write-Output "inferred application type: $ApplicationType"
}

if ($Interactive) {
    Write-Output "Interactive adapter setup. Press Enter to accept a default."
    if (-not [string]::IsNullOrWhiteSpace($inferredTarget.reason)) {
        Write-Output "Current inference: language=$($inferredTarget.language), framework=$($inferredTarget.framework), type=$($inferredTarget.application_type), confidence=$($inferredTarget.confidence)"
    }
    $ApplicationType = Read-AdapterChoice -Prompt "Application type (frontend/backend/systems/generic)" -DefaultValue $ApplicationType
    $Language = Read-AdapterChoice -Prompt "Language or runtime (typescript/python/c11/java/dotnet/go/rust)" -DefaultValue $Language
    $Framework = Read-AdapterChoice -Prompt "Framework or build system (next/express/fastapi/cmake/maven/none)" -DefaultValue $Framework
    $Runtime = Read-AdapterChoice -Prompt "Runtime or toolchain" -DefaultValue $Runtime
    $Ide = Read-AdapterChoice -Prompt "IDE or editor" -DefaultValue $Ide
}

if ([string]::IsNullOrWhiteSpace($Language) -and -not [string]::IsNullOrWhiteSpace($requirementsText)) {
    throw "requirements were supplied, but the script could not infer a stack confidently. Rerun with -Interactive or provide -Language and -Framework."
}

if ([string]::IsNullOrWhiteSpace($Framework)) {
    $Framework = "none"
}

$profile = Get-Content -Raw -LiteralPath $templatePath | ConvertFrom-Json
$shouldApplyPreset = -not [string]::IsNullOrWhiteSpace($Language)
if ($shouldApplyPreset) {
    $preset = Get-AdapterPreset -LanguageName $Language -FrameworkName $Framework
    if (-not [string]::IsNullOrWhiteSpace($ApplicationType)) {
        $preset.owners = New-StandardOwners -Kind $ApplicationType `
            -BuildCommand (Get-ProjectObjectProperty -Object $preset.commands -Name "build") `
            -UnitCommand (Get-ProjectObjectProperty -Object $preset.commands -Name "unit") `
            -IntegrationCommand (Get-ProjectObjectProperty -Object $preset.commands -Name "integration") `
            -BenchmarkCommand (Get-ProjectObjectProperty -Object $preset.commands -Name "benchmark_smoke")
    }
    Set-ProfileProperty -Object $profile -Name "commands" -Value $preset.commands
    Set-ProfileProperty -Object $profile -Name "owners" -Value $preset.owners
    if (-not [string]::IsNullOrWhiteSpace($preset.runtime) -and [string]::IsNullOrWhiteSpace($Runtime)) {
        $profile.project.runtime = $preset.runtime
    }
}
if (-not [string]::IsNullOrWhiteSpace($resolvedProjectName)) {
    $profile.project.name = $resolvedProjectName
}
if (-not [string]::IsNullOrWhiteSpace($Language)) {
    $profile.project.language = $Language
}
if (-not [string]::IsNullOrWhiteSpace($Runtime)) {
    $profile.project.runtime = $Runtime
}
if (-not [string]::IsNullOrWhiteSpace($Framework)) {
    $profile.project.framework = $Framework
}
if (-not [string]::IsNullOrWhiteSpace($Ide)) {
    $profile.project.ide = $Ide
}
if (-not [string]::IsNullOrWhiteSpace($requirementsText)) {
    $profile.project.summary = Get-RequirementSummary -Text $requirementsText
    $profile.requirements.success_criteria = @(Convert-RequirementsToCriteria -Text $requirementsText)
}

$profile = Set-HarnessProfileLayout $rootDir $profile
Write-AdapterFile -Path $profilePath -Content ($profile | ConvertTo-Json -Depth 20)

Write-AdapterFile -Path (Join-Path $projectPrompts "manager_main.md") -Content @'
# Manager Main Prompt

## Role

- own cross-module planning and integration decisions
- keep project work aligned with `harness/project/configs/project_profile.json`
- reconcile subagent output before promotion
- choose the smallest validation command that proves the current change

## Startup

1. read `AGENT.md`
2. read the active project profile
3. read the relevant requirement docs listed in the profile
4. check `harness/reports/latest_report.md` when available

## Output

- current priority
- owner assignment or direct fix
- validation command
- remaining risk
'@

Write-AdapterFile -Path (Join-Path $projectPrompts "manager_main_seed.md") -Content @'
# Manager Main Seed Plan Format

Use this when manager-main needs to create executable subagent work.

Write seed plans under `harness/reports/seed_plans/`.

## Required Shape

```md
# Assignment Seed Plan

## Meta

- plan_id: <short-unique-id>
- summary: <one-line summary>
- dispatch_mode: serial

## Assignment

- owner: <owner from project profile>
- title: <short stable task title>
- work_area: <optional override>
- validation: <optional override>

### Task

<concrete task>

### Acceptance

- <observable pass condition>

### Notes

none
```
'@

Write-AdapterFile -Path (Join-Path $projectPrompts "manager_harness.md") -Content @'
# Manager Harness Prompt

## Role

- maintain harness scripts, configs, reports, and git workflow safety
- keep reusable core separate from `harness/project/`
- classify failures and route retry work to the correct owner

## Standard Checks

1. `pwsh -NoProfile -File harness/scripts/run_harness_preflight.ps1`
2. `pwsh -NoProfile -File harness/scripts/run_harness_cycle.ps1`
3. targeted git gate commands when preparing commits or promotions

## Output

- command results
- failure class
- responsible owner
- next action
'@

Write-AdapterFile -Path (Join-Path $projectRoot "README.md") -Content @'
# Project Adapter

This directory contains project-specific harness configuration and prompts.

## Files

- `configs/project_profile.json`
- `prompts/manager_main.md`
- `prompts/manager_main_seed.md`
- `prompts/manager_harness.md`

The reusable harness core should not require project-specific edits outside this directory unless the profile schema itself is insufficient.
'@

Ensure-HarnessDirectory -Path (Join-Path $rootDir "docs")

$requirementsDocBody = @"
# Requirements

## Product Goal

Define the target product behavior for `$resolvedProjectName`.

## Success Criteria

- build command passes
- unit command passes
- integration command passes
- benchmark or smoke command passes
"@

if (-not [string]::IsNullOrWhiteSpace($requirementsText)) {
    $criteriaLines = (Convert-RequirementsToCriteria -Text $requirementsText | ForEach-Object { "- $_" }) -join [Environment]::NewLine
    $requirementsDocBody = @"
# Requirements

## Product Goal

$requirementsText

## Success Criteria

$criteriaLines
"@
}

$enginePrefix = if ((Get-HarnessEngineRoot $rootDir) -eq [IO.Path]::GetFullPath($rootDir)) { '' } else { 'harness/' }
Write-SeedFileIfMissing -Path (Join-Path $rootDir "AGENT.md") -Content @"
# $resolvedProjectName Agent Guide

## Project

- language: $($profile.project.language)
- runtime: $($profile.project.runtime)
- framework: $($profile.project.framework)
- summary: $($profile.project.summary)

## Harness

- profile: ${enginePrefix}project/configs/project_profile.json
- preflight: pwsh -NoProfile -File ${enginePrefix}scripts/run_harness_preflight.ps1
- full cycle: pwsh -NoProfile -File ${enginePrefix}scripts/run_harness_cycle.ps1

Keep project-specific harness changes under ${enginePrefix}project/.
"@

if (-not [string]::IsNullOrWhiteSpace($requirementsText) -and $Force) {
    Write-AdapterFile -Path (Resolve-ProjectPath -RootDir $rootDir -ProjectPath "docs/requirements.md" -Label "requirements doc") -Content $requirementsDocBody
} else {
    Write-SeedFileIfMissing -Path (Resolve-ProjectPath -RootDir $rootDir -ProjectPath "docs/requirements.md" -Label "requirements doc") -Content $requirementsDocBody
}

Write-SeedFileIfMissing -Path (Resolve-ProjectPath -RootDir $rootDir -ProjectPath "docs/requirements_raw_links.md" -Label "requirement sources doc") -Content @"
# Requirement Sources

Add source links, notes, tickets, or upstream references used to define the project requirements.
"@

Write-SeedFileIfMissing -Path (Resolve-ProjectPath -RootDir $rootDir -ProjectPath "docs/env_manifest.md" -Label "env manifest doc") -Content @"
# Environment Manifest

## Policy

- Do not commit real private tokens, passwords, API keys, or personal credentials.
- Record required environment variable names and safe local/mock setup here.

## Environment Variables

| name | purpose | required_later | `.env.example` value |
| --- | --- | --- | --- |
| none | not specified | no | none |

## Prepared Data

- none

## External Dependencies

- none

## Secrets And Access

- none
"@

$subagentPlanTemplate = Resolve-HarnessEnginePath -RootDir $rootDir -ProjectPath "harness/docs/subagent_plan.template.md" -Label "subagent plan template"
if (Test-Path -LiteralPath $subagentPlanTemplate) {
    $subagentPlanContent = Get-Content -Raw -LiteralPath $subagentPlanTemplate
} else {
    $subagentPlanContent = @"
# Subagent Plan

Define owner boundaries, read order, validation commands, and delivery order for this project.
"@
}
Write-SeedFileIfMissing -Path (Resolve-ProjectPath -RootDir $rootDir -ProjectPath "docs/subagent_plan.md" -Label "subagent plan doc") -Content $subagentPlanContent

$firstPromptsTemplate = Resolve-HarnessEnginePath -RootDir $rootDir -ProjectPath "harness/docs/subagent_first_prompts.template.md" -Label "subagent first prompts template"
if (Test-Path -LiteralPath $firstPromptsTemplate) {
    $firstPromptsContent = Get-Content -Raw -LiteralPath $firstPromptsTemplate
} else {
    $firstPromptsContent = @"
# Subagent First Prompts

Add the first prompt for each configured owner before dispatching live work.
"@
}
Write-SeedFileIfMissing -Path (Resolve-ProjectPath -RootDir $rootDir -ProjectPath "docs/subagent_first_prompts.md" -Label "subagent first prompts doc") -Content $firstPromptsContent

$gitIgnoreTemplate = Resolve-HarnessEnginePath -RootDir $rootDir -ProjectPath "harness/configs/gitignore.template" -Label "gitignore template"
if (Test-Path -LiteralPath $gitIgnoreTemplate) {
    $gitIgnoreContent = Get-Content -Raw -LiteralPath $gitIgnoreTemplate
} else {
    $gitIgnoreContent = @"
harness/reports/logs/
harness/reports/test_results/
harness/reports/retry_prompts/
harness/reports/seed_plans/
harness/reports/dispatch_packets/
harness/reports/agent_runs/
harness/reports/git_workflow/
harness/reports/latest_report.md
harness/reports/preflight_report.md
harness/state/locks/
harness/state/worktrees/
harness/state/git_workflow/
"@
}
Write-SeedFileIfMissing -Path (Join-Path $rootDir ".gitignore") -Content (Convert-HarnessLayoutText $rootDir $gitIgnoreContent)

$gitAttributesTemplate = Resolve-HarnessEnginePath -RootDir $rootDir -ProjectPath "harness/configs/gitattributes.template" -Label "gitattributes template"
if (Test-Path -LiteralPath $gitAttributesTemplate) {
    $gitAttributesContent = Get-Content -Raw -LiteralPath $gitAttributesTemplate
} else {
    $gitAttributesContent = @"
* text=auto
*.sh text eol=lf
harness/githooks/* text eol=lf
*.ps1 text
*.json text
*.md text
"@
}
Write-SeedFileIfMissing -Path (Join-Path $rootDir ".gitattributes") -Content (Convert-HarnessLayoutText $rootDir $gitAttributesContent)

$generateProfileDocs = Join-Path $PSScriptRoot "generate_profile_docs.ps1"
if (Test-Path -LiteralPath $generateProfileDocs) {
    $generateProfileResult = Invoke-HarnessPowerShellFile -FilePath $generateProfileDocs -AllowFailure
    if (-not $generateProfileResult.Success) {
        throw "failed to generate profile docs"
    }
}

if ($RunPreflight) {
    $installHooksScript = Join-Path $PSScriptRoot "install_git_hooks.ps1"
    if (Test-Path -LiteralPath $installHooksScript) {
        $installHooksResult = Invoke-HarnessPowerShellFile -FilePath $installHooksScript -AllowFailure
        if (-not $installHooksResult.Success) {
            throw "failed to install git hooks"
        }
    }

    $preflightResult = Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot "run_harness_preflight.ps1") -AllowFailure
    if (-not [string]::IsNullOrWhiteSpace($preflightResult.Output)) {
        Write-Output $preflightResult.Output
    }
    if (-not $preflightResult.Success) {
        throw "preflight failed"
    }
}
