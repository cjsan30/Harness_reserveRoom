param(
    [string]$PullRequest,
    [string]$ApprovalId,
    [ValidateSet("merge", "squash", "rebase", "queue", "auto")]
    [string]$MergeMode = "merge",
    [switch]$DeleteBranch,
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

$config = Get-GitWorkflowConfig -RootDir $rootDir
$pr = Get-GitHubPullRequestView -RootDir $rootDir -Selector $PullRequest
if ($pr.state -ne "OPEN") {
    throw "pull request is not open: $($pr.url)"
}
if ($pr.isDraft) {
    throw "draft pull request cannot be merged by harness: $($pr.url)"
}
if ($pr.baseRefName -ne $config.MainBranch) {
    throw "PR merge control only targets git_workflow.main_branch ('$($config.MainBranch)')"
}

$sourceBranch = [string]$pr.headRefName
$sourceHead = [string]$pr.headRefOid
$branchInfo = Get-GitBranchDescriptor -RootDir $rootDir -BranchName $sourceBranch
if ($branchInfo.Kind -ne "test") {
    throw "main PR source must be a dedicated test branch: $sourceBranch"
}

$localSourceHead = Get-GitBranchCommit -RootDir $rootDir -BranchName $sourceBranch
if ($localSourceHead -ne $sourceHead) {
    throw "local source branch must exist and match PR head. local='$localSourceHead' pr='$sourceHead'"
}
$sourceTree = Get-GitBranchTree -RootDir $rootDir -BranchName $sourceBranch

$state = Get-GitWorkflowState -RootDir $rootDir
$finalGate = Get-LatestGitValidation -State $state -Branch $sourceBranch -Stage "final" -Status "pass" -TreeHash $sourceTree
if ($null -eq $finalGate) {
    throw "source branch is missing a passing final gate for tree $sourceTree"
}

$auditIssues = Get-GitBranchAuditIssues -RootDir $rootDir -State $state -BranchName $sourceBranch -Commit $sourceHead
if ($auditIssues.Count -gt 0) {
    throw "source branch failed workflow audit:`n- $($auditIssues -join ([Environment]::NewLine + "- "))"
}

$approval = Get-BoundGitApproval -State $state -RootDir $rootDir -ApprovalId $ApprovalId -SourceBranch $sourceBranch -SourceHead $sourceHead -TargetBranch $config.MainBranch
if ($null -eq $approval) {
    throw "approved local main merge approval is required before PR merge"
}

$promotion = Get-LatestGitPromotion -State $state -SourceBranch $sourceBranch -SourceHead $sourceHead -TargetBranch $config.MainBranch -Status "authorized"
if ($null -eq $promotion) {
    Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot "authorize_branch_promotion.ps1") -Arguments @("-SourceBranch", $sourceBranch, "-TargetBranch", $config.MainBranch, "-ApprovalId", $approval.id, "-AuthorizedBy", "pr-control", "-RepositoryRoot", $rootDir) | Out-Null
}

$checks = Get-GitHubPullRequestChecks -RootDir $rootDir -Selector ([string]$pr.number) -RequiredOnly
$checkStatus = Get-GitHubChecksStatus -Checks $checks -AllowNoChecks:$AllowNoChecks
if ($checkStatus.Status -ne "pass") {
    throw "required PR checks are not passing: $($checkStatus.Status)"
}

$mergeArgs = @("pr", "merge", ([string]$pr.number), "--match-head-commit", $sourceHead)
switch ($MergeMode) {
    "merge" { $mergeArgs += "--merge" }
    "squash" { $mergeArgs += "--squash" }
    "rebase" { $mergeArgs += "--rebase" }
    "auto" { $mergeArgs += @("--auto", "--merge") }
    "queue" { }
}
if ($DeleteBranch) {
    $mergeArgs += "--delete-branch"
}

$mergeResult = Invoke-GitHubCli -RootDir $rootDir -Arguments $mergeArgs

$reportContent = @"
# Pull Request Merge

## Summary

- status: requested
- number: $($pr.number)
- url: $($pr.url)
- source_branch: $sourceBranch
- source_head: $sourceHead
- target_branch: $($pr.baseRefName)
- merge_mode: $MergeMode
- approval_id: $($approval.id)
- final_gate_report: $($finalGate.report)

## Output

$($mergeResult.Output)
"@
$reportPath = Write-GitWorkflowReport -RootDir $rootDir -Prefix ("pr_merge_" + $pr.number) -Content $reportContent

Write-Output "status: requested"
Write-Output "pr_number: $($pr.number)"
Write-Output "pr_url: $($pr.url)"
Write-Output "report: $reportPath"
