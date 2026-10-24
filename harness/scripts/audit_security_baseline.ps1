param(
    [switch]$CheckGitHubSecuritySettings,
    [switch]$RequireGitHubSecuritySettings,
    [switch]$WarnOnly,
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
. (Join-Path $PSScriptRoot "platform_engineering_common.ps1")
. (Join-Path $PSScriptRoot "security_quality_common.ps1")

$rootDir = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Get-HarnessRoot -ScriptDirectory $PSScriptRoot
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}

$security = Get-HarnessSecurityStack -RootDir $rootDir
$issues = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

$dependabotPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath ".github/dependabot.yml" -Label "dependabot"
$codeqlPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath ".github/workflows/codeql.yml" -Label "codeql workflow"
$scorecardPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath ".github/workflows/scorecard.yml" -Label "scorecard workflow"
$baselinePath = Resolve-HarnessEnginePath -RootDir $rootDir -ProjectPath "harness/project/configs/security_baseline.json" -Label "security baseline"

if (-not (Test-Path -LiteralPath $dependabotPath)) {
    $issues.Add("missing .github/dependabot.yml") | Out-Null
} else {
    $dependabotText = Get-Content -Raw -LiteralPath $dependabotPath
    foreach ($marker in @("version: 2", "package-ecosystem: `"github-actions`"", "schedule:", "interval: `"weekly`"")) {
        if ($dependabotText -notmatch [System.Text.RegularExpressions.Regex]::Escape($marker)) {
            $issues.Add("dependabot.yml missing marker: $marker") | Out-Null
        }
    }
    foreach ($update in @($security.DependabotUpdates)) {
        $marker = "package-ecosystem: `"$($update.ecosystem)`""
        if ($dependabotText -notmatch [System.Text.RegularExpressions.Regex]::Escape($marker)) {
            $warnings.Add("dependabot.yml does not include expected ecosystem: $($update.ecosystem)") | Out-Null
        }
    }
}

if ($security.CodeQlLanguages.Count -gt 0) {
    if (-not (Test-Path -LiteralPath $codeqlPath)) {
        $issues.Add("missing .github/workflows/codeql.yml") | Out-Null
    } else {
        $codeqlText = Get-Content -Raw -LiteralPath $codeqlPath
        foreach ($marker in @("github/codeql-action/init@v4", "github/codeql-action/analyze@v4", "security-events: write", "queries: security-and-quality")) {
            if ($codeqlText -notmatch [System.Text.RegularExpressions.Regex]::Escape($marker)) {
                $issues.Add("codeql workflow missing marker: $marker") | Out-Null
            }
        }
        foreach ($language in @($security.CodeQlLanguages)) {
            if ($codeqlText -notmatch [System.Text.RegularExpressions.Regex]::Escape([string]$language)) {
                $issues.Add("codeql workflow missing language: $language") | Out-Null
            }
        }
    }
} else {
    $warnings.Add("CodeQL workflow was not required because the active language is not mapped to CodeQL") | Out-Null
}

if (-not (Test-Path -LiteralPath $scorecardPath)) {
    $issues.Add("missing .github/workflows/scorecard.yml") | Out-Null
} else {
    $scorecardText = Get-Content -Raw -LiteralPath $scorecardPath
    foreach ($marker in @("ossf/scorecard-action@v2.4.3", "security-events: write", "id-token: write", "results_format: sarif", "github/codeql-action/upload-sarif@v4")) {
        if ($scorecardText -notmatch [System.Text.RegularExpressions.Regex]::Escape($marker)) {
            $issues.Add("scorecard workflow missing marker: $marker") | Out-Null
        }
    }
}

if (-not (Test-Path -LiteralPath $baselinePath)) {
    $issues.Add("missing harness/project/configs/security_baseline.json") | Out-Null
}

if ($CheckGitHubSecuritySettings) {
    try {
        . (Join-Path $PSScriptRoot "github_pr_common.ps1")
        . (Join-Path $PSScriptRoot "github_policy_common.ps1")
        Assert-GitHubCliAuthenticated -RootDir $rootDir
        $result = Invoke-GitHubApi -RootDir $rootDir -Endpoint "repos/{owner}/{repo}"
        $repo = Convert-GitHubJson -JsonText $result.Output -Label "github repository"
        $analysis = $repo.security_and_analysis
        foreach ($entry in @(
                @{ Name = "dependabot_security_updates"; Label = "Dependabot security updates" },
                @{ Name = "secret_scanning"; Label = "secret scanning" },
                @{ Name = "secret_scanning_push_protection"; Label = "secret scanning push protection" }
            )) {
            $setting = Get-ProjectObjectProperty -Object $analysis -Name $entry.Name
            $status = [string](Get-ProjectObjectProperty -Object $setting -Name "status")
            if ($status -ne "enabled") {
                $message = "$($entry.Label) is not enabled in GitHub security_and_analysis"
                if ($RequireGitHubSecuritySettings) {
                    $issues.Add($message) | Out-Null
                } else {
                    $warnings.Add($message) | Out-Null
                }
            }
        }
    } catch {
        $message = "GitHub security settings audit failed: $($_.Exception.Message)"
        if ($RequireGitHubSecuritySettings) {
            $issues.Add($message) | Out-Null
        } else {
            $warnings.Add($message) | Out-Null
        }
    }
}

$status = $(if ($issues.Count -eq 0) { "pass" } else { "fail" })
$report = @"
# Security Baseline Audit

## Summary

- status: $status
- issues: $($issues.Count)
- warnings: $($warnings.Count)
- github_security_settings_checked: $([bool]$CheckGitHubSecuritySettings)

## Issues

$(Format-HarnessSecurityList -Items $issues.ToArray())

## Warnings

$(Format-HarnessSecurityList -Items $warnings.ToArray())
"@
$reportPath = Write-HarnessReportFile -RootDir $rootDir -FileName "security_baseline_audit.md" -Content $report

Write-Output "status: $status"
Write-Output "issues: $($issues.Count)"
Write-Output "warnings: $($warnings.Count)"
Write-Output "report: $reportPath"

if ($status -ne "pass" -and -not $WarnOnly) {
    exit 1
}
