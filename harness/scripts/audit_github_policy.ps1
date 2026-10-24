param(
    [string]$MainBranch,
    [string]$RequiredCheckName = "Harness CI",
    [int]$RequiredApprovals = 1,
    [switch]$RequireCodeOwnerReview,
    [switch]$RequireMergeQueue,
    # Audit another branch (e.g. dev); defaults to the workflow main branch.
    [string]$Branch,
    # Check only deletion and force-push protection.
    [switch]$ProtectionOnly,
    [switch]$WarnOnly,
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
. (Join-Path $PSScriptRoot "git_workflow_common.ps1")
. (Join-Path $PSScriptRoot "github_pr_common.ps1")
. (Join-Path $PSScriptRoot "github_policy_common.ps1")

$rootDir = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Get-HarnessRoot -ScriptDirectory $PSScriptRoot
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}

$config = Get-GitWorkflowConfig -RootDir $rootDir
if ([string]::IsNullOrWhiteSpace($MainBranch)) {
    $MainBranch = $config.MainBranch
}
if ([string]::IsNullOrWhiteSpace($Branch)) {
    $Branch = $MainBranch
}

Assert-GitHubCliAuthenticated -RootDir $rootDir
$audit = Get-GitHubPolicyAudit -RootDir $rootDir -MainBranch $Branch -RequiredCheckName $RequiredCheckName -RequiredApprovals $RequiredApprovals -RequireCodeOwnerReview:$RequireCodeOwnerReview -RequireMergeQueue:$RequireMergeQueue -ProtectionOnly:$ProtectionOnly

$matchingRulesetLines = if ($audit.MatchingRulesets.Count -eq 0) {
    "- none"
} else {
    ($audit.MatchingRulesets | ForEach-Object { "- $($_.name) (#$($_.id))" }) -join [Environment]::NewLine
}

$reportContent = @"
# GitHub Policy Audit

## Summary

- status: $($audit.Status)
- repository: $($audit.Repository.NameWithOwner)
- repository_url: $($audit.Repository.Url)
- github_default_branch: $($audit.Repository.DefaultBranch)
- audited_branch: $($audit.MainBranch)
- protection_only: $($audit.ProtectionOnly)
- required_check: $($audit.RequiredCheckName)
- required_approvals: $($audit.RequiredApprovals)
- require_code_owner_review: $($audit.RequireCodeOwnerReview)
- require_merge_queue: $($audit.RequireMergeQueue)
- matching_rulesets: $($audit.MatchingRulesets.Count)
- issues: $($audit.Issues.Count)
- warnings: $($audit.Warnings.Count)

## Matching Rulesets

$matchingRulesetLines

## Issues

$(Format-GitHubPolicyList -Items $audit.Issues)

## Warnings

$(Format-GitHubPolicyList -Items $audit.Warnings)
"@

$reportPath = Write-GitWorkflowReport -RootDir $rootDir -Prefix "github_policy_audit" -Content $reportContent

Write-Output "status: $($audit.Status)"
Write-Output "repository: $($audit.Repository.NameWithOwner)"
Write-Output "branch: $($audit.MainBranch)"
Write-Output "protection_only: $($audit.ProtectionOnly)"
Write-Output "required_check: $($audit.RequiredCheckName)"
Write-Output "issues: $($audit.Issues.Count)"
Write-Output "warnings: $($audit.Warnings.Count)"
Write-Output "report: $reportPath"

if ($audit.Status -ne "pass" -and -not $WarnOnly) {
    exit 1
}
