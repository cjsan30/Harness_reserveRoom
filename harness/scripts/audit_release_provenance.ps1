param(
    [switch]$WarnOnly,
    [string]$WorkflowPath = ".github/workflows/harness-release-provenance.yml",
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
$path = Resolve-ProjectPath -RootDir $rootDir -ProjectPath $WorkflowPath -Label "release provenance workflow"

if (-not (Test-Path -LiteralPath $path)) {
    $issues.Add("missing workflow: $WorkflowPath") | Out-Null
} else {
    $text = Get-Content -Raw -LiteralPath $path
    foreach ($pattern in @("id-token: write", "attestations: write", "actions/attest@v4", "actions/upload-artifact@v4", "subject-path:", (Convert-HarnessLayoutPath $rootDir 'harness/release-artifacts'))) {
        if ($text -notmatch [System.Text.RegularExpressions.Regex]::Escape($pattern)) {
            $issues.Add("release provenance workflow is missing expected marker: $pattern") | Out-Null
        }
    }
    if ($text -notmatch "workflow_dispatch:") {
        $warnings.Add("release provenance workflow cannot be manually dispatched") | Out-Null
    }
}

$status = $(if ($issues.Count -eq 0) { "pass" } else { "fail" })
$issueLines = if ($issues.Count -eq 0) { "- none" } else { ($issues.ToArray() | ForEach-Object { "- " + $_ }) -join [Environment]::NewLine }
$warningLines = if ($warnings.Count -eq 0) { "- none" } else { ($warnings.ToArray() | ForEach-Object { "- " + $_ }) -join [Environment]::NewLine }
$report = @"
# Release Provenance Audit

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
$reportPath = Write-HarnessReportFile -RootDir $rootDir -FileName "release_provenance_audit.md" -Content $report

Write-Output "status: $status"
Write-Output "issues: $($issues.Count)"
Write-Output "warnings: $($warnings.Count)"
Write-Output "report: $reportPath"

if ($status -ne "pass" -and -not $WarnOnly) {
    exit 1
}
