param([string]$OutputDirectory = "")

# Project adapter and bootstrap regressions found while porting the engine into a
# real Spring Boot repository (local_notes/field_findings.md F-01..F-09). Isolated
# Git fixtures only; no AI provider, network, or installed hook is used.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$engineRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $engineRoot '.test-output' }
$testRoot = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ([Guid]::NewGuid().ToString('N'))
Ensure-HarnessDirectory $testRoot
$results = New-Object 'System.Collections.Generic.List[object]'
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $results.Add(@{name=$Name; passed=$true}); Write-Output "PASS $Name" }
    catch { $results.Add(@{name=$Name; passed=$false; error=$_.Exception.Message}); Write-Output "FAIL $Name : $($_.Exception.Message)" }
}
function New-AdapterFixture([string]$Name, [switch]$GradleWrapper, [string]$ExistingGitignore = '') {
    $root = Join-Path $testRoot $Name
    $engine = Join-Path $root 'harness'
    Ensure-HarnessDirectory $engine
    foreach ($directory in @('scripts', 'configs', 'docs', 'project', 'githooks')) {
        Copy-Item -LiteralPath (Join-Path $engineRoot $directory) -Destination (Join-Path $engine $directory) -Recurse
    }
    # Only the tracked report templates; the engine checkout's runtime reports stay out.
    Ensure-HarnessDirectory (Join-Path $engine 'reports')
    foreach ($template in @(Get-ChildItem -LiteralPath (Join-Path $engineRoot 'reports') -Filter '*_template.md' -File)) {
        Copy-Item -LiteralPath $template.FullName -Destination (Join-Path $engine 'reports')
    }
    if ($GradleWrapper) {
        Write-Utf8File (Join-Path $root 'gradlew') "#!/bin/sh`n"
        Write-Utf8File (Join-Path $root 'gradlew.bat') "@echo off`r`n"
    }
    if ($ExistingGitignore) { Write-Utf8File (Join-Path $root '.gitignore') $ExistingGitignore }
    Invoke-HarnessProcess git @('init', '-q', '-b', 'main', $root) | Out-Null
    return $root
}
function Invoke-Adapter([string]$Root, [string[]]$Arguments) {
    return Invoke-HarnessPowerShellFile -FilePath (Join-Path $Root 'harness/scripts/init_project_adapter.ps1') -Arguments $Arguments -AllowFailure
}
function Read-FixtureProfile([string]$Root) {
    return Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $Root 'harness/project/configs/project_profile.json') | ConvertFrom-Json
}

$previousRoot = $env:CODEX_HARNESS_ROOT
$previousWorkspace = $env:CODEX_GIT_WORKSPACE_ROOT
$env:CODEX_HARNESS_ROOT = $null
$env:CODEX_GIT_WORKSPACE_ROOT = $null
try {
    $springIgnore = "HELP.md`n.gradle`nbuild/`n### IntelliJ IDEA ###`n.idea`n"
    $spring = New-AdapterFixture 'spring [safe] app' -GradleWrapper -ExistingGitignore $springIgnore
    $adapter = Invoke-Adapter $spring @('-ProjectName', 'fixture-app', '-Language', 'java', '-Framework', 'gradle', '-Force')

    Test-Case 'java adapter runs successfully on a Spring-style repository' {
        Assert-True $adapter.Success $adapter.Output
    }
    Test-Case 'gradle wrapper is preferred with an explicit path (F-01, F-03)' {
        $profile = Read-FixtureProfile $spring
        $wrapper = if (Test-HarnessIsWindows) { '.\gradlew.bat' } else { './gradlew' }
        foreach ($name in @('build', 'unit', 'integration', 'benchmark_smoke', 'release')) {
            $command = [string]$profile.commands.$name
            Assert-True ($command.StartsWith($wrapper + ' ')) "commands.$name does not use the wrapper: $command"
        }
        Assert-True ([string]$profile.owners.'agent-api'.validation -eq ($wrapper + ' test')) "owner validation: $($profile.owners.'agent-api'.validation)"
    }
    Test-Case 'without a wrapper the gradle preset keeps the global command' {
        $plain = New-AdapterFixture 'plain gradle'
        $result = Invoke-Adapter $plain @('-ProjectName', 'plain-app', '-Language', 'java', '-Framework', 'gradle', '-Force')
        Assert-True $result.Success $result.Output
        Assert-True ([string](Read-FixtureProfile $plain).commands.unit -eq 'gradle test') 'global gradle fallback changed'
    }
    Test-Case 'JVM owners use the standard source layout (F-02)' {
        $owners = (Read-FixtureProfile $spring).owners
        Assert-True ($owners.'agent-api'.work_area -eq 'src/main/java' -and $owners.'agent-domain'.work_area -eq 'src/main/java') 'java source area'
        Assert-True ($owners.'agent-data'.work_area -eq 'src/main/resources' -and $owners.'agent-tests'.work_area -eq 'src/test') 'resources/test area'
        foreach ($property in $owners.PSObject.Properties) {
            Assert-True (-not ([string]$property.Value.work_area).StartsWith('src/api')) "legacy area remained: $($property.Name)"
        }
    }
    Test-Case 'worker owners read only the essential documents (F-09)' {
        $owners = (Read-FixtureProfile $spring).owners
        foreach ($property in $owners.PSObject.Properties) {
            if (-not $property.Name.StartsWith('agent-')) { continue }
            $read = @($property.Value.read)
            Assert-True (($read -join ',') -eq 'AGENT.md,docs/requirements.md,docs/env_manifest.md') "$($property.Name) reads: $($read -join ',')"
        }
        Assert-True (@($owners.'manager-main'.read).Count -gt 3) 'manager planning documents were reduced'
    }
    Test-Case 'existing .gitignore keeps its rules and gains the harness section (F-04, F-05)' {
        $text = [IO.File]::ReadAllText((Join-Path $spring '.gitignore'))
        Assert-True ($text.StartsWith('HELP.md')) 'existing rules were not kept first'
        foreach ($rule in @('harness/state/locks/', 'harness/assignments/*/.queue/', '.githooks/', '.env')) {
            Assert-True (@($text -split "\r?\n" | Where-Object { $_.Trim() -eq $rule }).Count -eq 1) "missing or duplicated rule: $rule"
        }
        $attributes = [IO.File]::ReadAllText((Join-Path $spring '.gitattributes'))
        Assert-True ($attributes.Contains('harness/githooks/* text eol=lf')) 'harness attribute rules missing'
    }
    Test-Case 'rerunning the adapter does not duplicate merged rules' {
        $again = Invoke-Adapter $spring @('-ProjectName', 'fixture-app', '-Language', 'java', '-Framework', 'gradle', '-Force')
        Assert-True $again.Success $again.Output
        Assert-True ($again.Output.Contains('kept existing (harness rules present)')) 'second run did not detect the merged rules'
        $text = [IO.File]::ReadAllText((Join-Path $spring '.gitignore'))
        Assert-True (([regex]::Matches($text, 'Harness runtime output')).Count -eq 1) 'harness section was added twice'
    }
    Test-Case 'seed documents expand template values (F-06)' {
        $requirements = [IO.File]::ReadAllText((Join-Path $spring 'docs/requirements.md'))
        Assert-True ($requirements.Contains('`fixture-app`')) "project name not rendered: $requirements"
        Assert-True (-not ($requirements -match '\$[A-Za-z]')) 'unexpanded variable in requirements.md'
        $manifest = [IO.File]::ReadAllText((Join-Path $spring 'docs/env_manifest.md'))
        Assert-True ($manifest.Contains('| `.env.example` value |')) 'env manifest header lost its code formatting'
    }
    Test-Case 'preflight warns about placeholders left in worker documents (F-07)' {
        $preflight = Invoke-HarnessPowerShellFile -FilePath (Join-Path $spring 'harness/scripts/run_harness_preflight.ps1') -AllowFailure
        $match = [regex]::Match($preflight.Output, 'preflight report: ([^\r\n]+)')
        Assert-True $match.Success $preflight.Output
        $report = [IO.File]::ReadAllText($match.Groups[1].Value.Trim())
        Assert-True ($report.Contains('source doc still contains template placeholders (replace-with-...): AGENT.md')) "placeholder warning missing: $report"
    }
    Test-Case 'bootstrap keeps engine report templates as commit candidates (F-08)' {
        $bootstrap = Invoke-HarnessPowerShellFile -FilePath (Join-Path $spring 'harness/scripts/bootstrap_initial_commit.ps1') -Arguments @('-DryRun') -AllowFailure
        Assert-True $bootstrap.Success $bootstrap.Output
        $plan = [IO.File]::ReadAllText((Join-Path $spring 'harness/reports/bootstrap_initial_commit_plan.md'))
        foreach ($template in @('harness/reports/report_template.md', 'harness/reports/retry_prompt_template.md')) {
            Assert-True ($plan.Contains('- ' + $template)) "template excluded from bootstrap: $template"
        }
        Assert-True (-not $plan.Contains('harness/reports/preflight_report.md')) 'runtime report became a bootstrap candidate'
    }
} finally {
    $env:CODEX_HARNESS_ROOT = $previousRoot
    $env:CODEX_GIT_WORKSPACE_ROOT = $previousWorkspace
}

Write-Utf8File (Join-Path $testRoot 'results.json') ($results.ToArray() | ConvertTo-Json -Depth 5)
$failed = @($results | Where-Object { -not $_.passed }).Count
Write-Output "Adapter results: $($results.Count - $failed)/$($results.Count) passed; artifacts: $testRoot"
if ($failed -gt 0) { exit 1 }
exit 0
