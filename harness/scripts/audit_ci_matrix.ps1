param(
    [switch]$WarnOnly,
    [string]$WorkflowPath = ".github/workflows/harness-ci.yml",
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
. (Join-Path $PSScriptRoot "platform_engineering_common.ps1")

$rootDir = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Get-HarnessRoot -ScriptDirectory $PSScriptRoot
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}

$issues = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$path = Resolve-ProjectPath -RootDir $rootDir -ProjectPath $WorkflowPath -Label "github actions workflow"

if (-not (Test-Path -LiteralPath $path)) {
    $issues.Add("missing workflow: $WorkflowPath") | Out-Null
} else {
    $text = Get-Content -Raw -LiteralPath $path
    foreach ($pattern in @("strategy:", "matrix:", "actions/cache@v4", "name: Harness CI", "needs: harness-matrix", "Start service dependencies", "Stop service dependencies")) {
        if ($text -notmatch [System.Text.RegularExpressions.Regex]::Escape($pattern)) {
            $issues.Add("workflow is missing expected CI matrix/cache marker: $pattern") | Out-Null
        }
    }
    if ($text -notmatch "hashFiles\(") {
        $issues.Add("workflow cache key does not use hashFiles") | Out-Null
    }
    if ($text -match "path:\s*\|\s*\r?\n\s+-\s+") {
        $issues.Add("workflow cache path block uses YAML list markers; actions/cache path blocks must contain raw newline-separated paths") | Out-Null
    }
    if ($text -notmatch "cancel-in-progress: true") {
        $warnings.Add("workflow does not cancel in-progress runs for the same ref") | Out-Null
    }
}

$status = $(if ($issues.Count -eq 0) { "pass" } else { "fail" })
$issueLines = if ($issues.Count -eq 0) { "- none" } else { ($issues.ToArray() | ForEach-Object { "- " + $_ }) -join [Environment]::NewLine }
$warningLines = if ($warnings.Count -eq 0) { "- none" } else { ($warnings.ToArray() | ForEach-Object { "- " + $_ }) -join [Environment]::NewLine }
$report = @"
# CI Matrix Audit

## Summary

- status: $status
- workflow: $WorkflowPath
- issues: $($issues.Count)
- warnings: $($warnings.Count)

## Issues

$issueLines

## Warnings

$warningLines
"@
$reportPath = Write-HarnessReportFile -RootDir $rootDir -FileName "ci_matrix_audit.md" -Content $report

Write-Output "status: $status"
Write-Output "issues: $($issues.Count)"
Write-Output "warnings: $($warnings.Count)"
Write-Output "report: $reportPath"

if ($status -ne "pass" -and -not $WarnOnly) {
    exit 1
}
