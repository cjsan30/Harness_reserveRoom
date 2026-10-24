param(
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

$issues = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$configPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath ".pre-commit-config.yaml" -Label "pre-commit config"

if (-not (Test-Path -LiteralPath $configPath)) {
    $issues.Add("missing .pre-commit-config.yaml") | Out-Null
} else {
    $text = Get-Content -Raw -LiteralPath $configPath
    foreach ($marker in @(
            "repo: https://github.com/pre-commit/pre-commit-hooks",
            "rev: v6.0.0",
            "id: trailing-whitespace",
            "id: end-of-file-fixer",
            "id: check-yaml",
            "id: check-json",
            "id: check-added-large-files",
            "id: detect-private-key",
            "id: mixed-line-ending"
        )) {
        if ($text -notmatch [System.Text.RegularExpressions.Regex]::Escape($marker)) {
            $issues.Add("pre-commit config missing marker: $marker") | Out-Null
        }
    }
    if ($text -match "id:\s+no-commit-to-branch") {
        $warnings.Add("pre-commit config includes no-commit-to-branch; harness Git hooks already own protected-branch governance") | Out-Null
    }
}

$command = Get-Command "pre-commit" -ErrorAction SilentlyContinue
if ($null -eq $command) {
    $warnings.Add("pre-commit executable is not installed on PATH") | Out-Null
}

$hooksPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath ".githooks" -Label "git hooks"
if (-not (Test-Path -LiteralPath $hooksPath)) {
    $warnings.Add("harness .githooks directory is missing; pre-commit should not replace harness governance hooks") | Out-Null
}

$status = $(if ($issues.Count -eq 0) { "pass" } else { "fail" })
$report = @"
# Pre-commit Baseline Audit

## Summary

- status: $status
- issues: $($issues.Count)
- warnings: $($warnings.Count)

## Issues

$(Format-HarnessSecurityList -Items $issues.ToArray())

## Warnings

$(Format-HarnessSecurityList -Items $warnings.ToArray())
"@
$reportPath = Write-HarnessReportFile -RootDir $rootDir -FileName "precommit_baseline_audit.md" -Content $report

Write-Output "status: $status"
Write-Output "issues: $($issues.Count)"
Write-Output "warnings: $($warnings.Count)"
Write-Output "report: $reportPath"

if ($status -ne "pass" -and -not $WarnOnly) {
    exit 1
}
