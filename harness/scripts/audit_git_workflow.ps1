param(
    [switch]$Quiet,
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
. (Join-Path $PSScriptRoot "git_workflow_common.ps1")

$rootDir = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Get-HarnessRoot -ScriptDirectory $PSScriptRoot
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}

$state = Get-GitWorkflowState -RootDir $rootDir
$branchInfo = Get-GitBranchDescriptor -RootDir $rootDir
$issues = Get-GitBranchAuditIssues -RootDir $rootDir -State $state -BranchName $branchInfo.Name
$status = if ($issues.Count -eq 0) { "pass" } else { "fail" }

$issueLines = if ($issues.Count -eq 0) { "- none" } else { ($issues | ForEach-Object { "- $_" }) -join [Environment]::NewLine }
$report = @"
# Git Workflow Audit

## Summary

- status: $status
- branch: $($branchInfo.Name)
- branch_kind: $($branchInfo.Kind)

## Issues

$issueLines
"@

$reportPath = Write-GitWorkflowReport -RootDir $rootDir -Prefix ("audit_" + ($branchInfo.Name -replace "[^A-Za-z0-9_-]", "_")) -Content $report

if (-not $Quiet) {
    Write-Output "git workflow audit status: $status"
    Write-Output "audit report: $reportPath"
}

if ($status -ne "pass") {
    exit 1
}
