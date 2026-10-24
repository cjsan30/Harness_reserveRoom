param(
    [string]$PullRequest,
    [switch]$AllChecks,
    [switch]$AllowNoChecks,
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
. (Join-Path $PSScriptRoot "git_workflow_common.ps1")
. (Join-Path $PSScriptRoot "github_pr_common.ps1")

$rootDir = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Get-HarnessRoot -ScriptDirectory $PSScriptRoot
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}

if ([string]::IsNullOrWhiteSpace($PullRequest)) {
    $PullRequest = Get-GitCurrentBranch -RootDir $rootDir
}

$pr = Get-GitHubPullRequestView -RootDir $rootDir -Selector $PullRequest
$checks = Get-GitHubPullRequestChecks -RootDir $rootDir -Selector $PullRequest -RequiredOnly:(!$AllChecks)
$checkStatus = Get-GitHubChecksStatus -Checks $checks -AllowNoChecks:$AllowNoChecks

$status = $checkStatus.Status
if ($pr.state -ne "OPEN") {
    $status = "not_open"
} elseif ($pr.isDraft) {
    $status = "draft"
}

$checkLines = if ($checks.Count -eq 0) {
    "- none"
} else {
    ($checks | ForEach-Object { "- $($_.name): $($_.bucket) ($($_.state))" }) -join [Environment]::NewLine
}

$reportContent = @"
# Pull Request Status

## Summary

- status: $status
- number: $($pr.number)
- url: $($pr.url)
- state: $($pr.state)
- draft: $($pr.isDraft)
- head: $($pr.headRefName)@$($pr.headRefOid)
- base: $($pr.baseRefName)
- merge_state: $($pr.mergeStateStatus)
- review_decision: $($pr.reviewDecision)
- checks_pass: $($checkStatus.Pass)
- checks_fail: $($checkStatus.Fail)
- checks_pending: $($checkStatus.Pending)
- checks_other: $($checkStatus.Other)

## Checks

$checkLines
"@
$reportPath = Write-GitWorkflowReport -RootDir $rootDir -Prefix ("pr_status_" + $pr.number) -Content $reportContent

Write-Output "status: $status"
Write-Output "pr_number: $($pr.number)"
Write-Output "pr_url: $($pr.url)"
Write-Output "report: $reportPath"

if ($status -ne "pass") {
    exit 1
}
