function Get-HarnessSecurityStack {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir
    )

    $stack = Get-HarnessStackProfile -RootDir $RootDir
    $languageKey = [string]$stack.LanguageKey
    $frameworkKey = [string]$stack.FrameworkKey

    $dependabot = New-Object System.Collections.Generic.List[object]
    $dependabot.Add([ordered]@{ ecosystem = "github-actions"; directory = "/" }) | Out-Null
    $dependabot.Add([ordered]@{ ecosystem = "docker"; directory = "/" }) | Out-Null

    $codeqlLanguages = New-Object System.Collections.Generic.List[string]
    $precommitLocalHooks = New-Object System.Collections.Generic.List[object]

    switch -Regex ($languageKey) {
        "^(node|javascript|typescript|ts|js)$" {
            $dependabot.Add([ordered]@{ ecosystem = "npm"; directory = "/" }) | Out-Null
            $codeqlLanguages.Add("javascript-typescript") | Out-Null
            $precommitLocalHooks.Add([ordered]@{
                    id = "npm-lint-if-present"
                    name = "npm lint if present"
                    entry = "npm run lint --if-present"
                    language = "system"
                    pass_filenames = $false
                }) | Out-Null
            break
        }
        "^python" {
            $dependabot.Add([ordered]@{ ecosystem = "pip"; directory = "/" }) | Out-Null
            $codeqlLanguages.Add("python") | Out-Null
            $precommitLocalHooks.Add([ordered]@{
                    id = "python-bytecode-compile"
                    name = "python bytecode compile"
                    entry = "python -m py_compile"
                    language = "system"
                    types = @("python")
                }) | Out-Null
            break
        }
        "^(java|kotlin)$" {
            if ($frameworkKey -eq "maven") {
                $dependabot.Add([ordered]@{ ecosystem = "maven"; directory = "/" }) | Out-Null
            } else {
                $dependabot.Add([ordered]@{ ecosystem = "gradle"; directory = "/" }) | Out-Null
            }
            $codeqlLanguages.Add("java-kotlin") | Out-Null
            break
        }
        "^(c|c11|cpp|c\+\+)$" {
            $codeqlLanguages.Add("c-cpp") | Out-Null
            break
        }
        "^(dotnet|c#|csharp)$" {
            $dependabot.Add([ordered]@{ ecosystem = "nuget"; directory = "/" }) | Out-Null
            $codeqlLanguages.Add("csharp") | Out-Null
            $precommitLocalHooks.Add([ordered]@{
                    id = "dotnet-format-check"
                    name = "dotnet format check"
                    entry = "dotnet format --verify-no-changes"
                    language = "system"
                    pass_filenames = $false
                }) | Out-Null
            break
        }
        "^(go|golang)$" {
            $dependabot.Add([ordered]@{ ecosystem = "gomod"; directory = "/" }) | Out-Null
            $codeqlLanguages.Add("go") | Out-Null
            $precommitLocalHooks.Add([ordered]@{
                    id = "gofmt"
                    name = "gofmt"
                    entry = "gofmt -w"
                    language = "system"
                    types = @("go")
                }) | Out-Null
            break
        }
        "^rust" {
            $dependabot.Add([ordered]@{ ecosystem = "cargo"; directory = "/" }) | Out-Null
            $precommitLocalHooks.Add([ordered]@{
                    id = "cargo-fmt-check"
                    name = "cargo fmt check"
                    entry = "cargo fmt -- --check"
                    language = "system"
                    pass_filenames = $false
                }) | Out-Null
            break
        }
    }

    return [pscustomobject]@{
        Stack = $stack
        DependabotUpdates = $dependabot.ToArray()
        CodeQlLanguages = $codeqlLanguages.ToArray()
        PreCommitLocalHooks = $precommitLocalHooks.ToArray()
    }
}

function New-HarnessDependabotYaml {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Updates,
        [string]$Interval = "weekly"
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("version: 2") | Out-Null
    $lines.Add("updates:") | Out-Null
    foreach ($update in $Updates) {
        $lines.Add("  - package-ecosystem: `"$($update.ecosystem)`"") | Out-Null
        $lines.Add("    directory: `"$($update.directory)`"") | Out-Null
        $lines.Add("    schedule:") | Out-Null
        $lines.Add("      interval: `"$Interval`"") | Out-Null
        $lines.Add("      day: `"monday`"") | Out-Null
        $lines.Add("      time: `"09:00`"") | Out-Null
        $lines.Add("      timezone: `"Asia/Seoul`"") | Out-Null
        $lines.Add("    open-pull-requests-limit: 5") | Out-Null
        $lines.Add("    labels:") | Out-Null
        $lines.Add("      - `"dependencies`"") | Out-Null
        $lines.Add("      - `"harness-security`"") | Out-Null
    }

    return ($lines.ToArray() -join [Environment]::NewLine)
}

function New-HarnessCodeQlWorkflowYaml {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Languages
    )

    $languageLines = ($Languages | ForEach-Object { "          - " + $_ }) -join [Environment]::NewLine
    $compiledLanguages = @("c-cpp", "csharp", "java-kotlin", "go")
    $usesAutobuild = $false
    foreach ($language in $Languages) {
        if ($compiledLanguages -contains $language) {
            $usesAutobuild = $true
            break
        }
    }
    $autobuildStep = if ($usesAutobuild) {
@'

      - name: Autobuild
        uses: github/codeql-action/autobuild@v4
'@
    } else {
        ""
    }

    return @"
name: CodeQL

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main
  schedule:
    - cron: '31 2 * * 1'
  workflow_dispatch:

permissions:
  actions: read
  contents: read
  security-events: write
  packages: read

jobs:
  analyze:
    name: CodeQL (`${{ matrix.language }})
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        language:
$languageLines
    steps:
      - name: Checkout
        uses: actions/checkout@v6

      - name: Initialize CodeQL
        uses: github/codeql-action/init@v4
        with:
          languages: `${{ matrix.language }}
          queries: security-and-quality
$autobuildStep
      - name: Perform CodeQL Analysis
        uses: github/codeql-action/analyze@v4
"@
}

function New-HarnessScorecardWorkflowYaml {
    return @'
name: OpenSSF Scorecard

on:
  branch_protection_rule:
  schedule:
    - cron: '17 3 * * 2'
  workflow_dispatch:

permissions:
  contents: read
  security-events: write
  id-token: write

jobs:
  scorecard:
    name: OpenSSF Scorecard
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v6
        with:
          persist-credentials: false

      - name: Run OpenSSF Scorecard
        uses: ossf/scorecard-action@v2.4.3
        with:
          results_file: scorecard-results.sarif
          results_format: sarif
          publish_results: true

      - name: Upload SARIF
        uses: github/codeql-action/upload-sarif@v4
        with:
          sarif_file: scorecard-results.sarif
'@
}

function New-HarnessPreCommitYaml {
    param(
        [object[]]$LocalHooks
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("minimum_pre_commit_version: `"3.7.0`"") | Out-Null
    $lines.Add("default_install_hook_types:") | Out-Null
    $lines.Add("  - pre-commit") | Out-Null
    $lines.Add("repos:") | Out-Null
    $lines.Add("  - repo: https://github.com/pre-commit/pre-commit-hooks") | Out-Null
    $lines.Add("    rev: v6.0.0") | Out-Null
    $lines.Add("    hooks:") | Out-Null
    foreach ($hookId in @("trailing-whitespace", "end-of-file-fixer", "check-yaml", "check-json", "check-added-large-files", "detect-private-key", "mixed-line-ending")) {
        $lines.Add("      - id: $hookId") | Out-Null
        if ($hookId -eq "check-added-large-files") {
            $lines.Add("        args: [--maxkb=1024]") | Out-Null
        }
        if ($hookId -eq "mixed-line-ending") {
            $lines.Add("        args: [--fix=lf]") | Out-Null
        }
    }

    if ($LocalHooks.Count -gt 0) {
        $lines.Add("  - repo: local") | Out-Null
        $lines.Add("    hooks:") | Out-Null
        foreach ($hook in $LocalHooks) {
            $lines.Add("      - id: $($hook.id)") | Out-Null
            $lines.Add("        name: $($hook.name)") | Out-Null
            $lines.Add("        entry: $($hook.entry)") | Out-Null
            $lines.Add("        language: $($hook.language)") | Out-Null
            if ($null -ne $hook.pass_filenames) {
                $lines.Add("        pass_filenames: $(([bool]$hook.pass_filenames).ToString().ToLowerInvariant())") | Out-Null
            }
            if ($null -ne $hook.types) {
                $lines.Add("        types:") | Out-Null
                foreach ($type in @($hook.types)) {
                    $lines.Add("          - $type") | Out-Null
                }
            }
        }
    }

    return ($lines.ToArray() -join [Environment]::NewLine)
}

function Format-HarnessSecurityList {
    param(
        [AllowEmptyCollection()]
        [object[]]$Items,
        [string]$EmptyText = "none"
    )

    if ($null -eq $Items -or $Items.Count -eq 0) {
        return "- $EmptyText"
    }

    return (($Items | ForEach-Object { "- " + [string]$_ }) -join [Environment]::NewLine)
}
