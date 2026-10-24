param(
    [Parameter(Mandatory = $true)]
    [string]$SourceBranch,
    [string]$TargetBranch,
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

$config = Get-GitWorkflowConfig -RootDir $rootDir
if ([string]::IsNullOrWhiteSpace($TargetBranch)) {
    $TargetBranch = Get-GitCurrentBranch -RootDir $rootDir
}

if ($TargetBranch -ne $config.DevBranch -and $TargetBranch -ne $config.MainBranch) {
    throw "target branch must match git_workflow.dev_branch ('$($config.DevBranch)') or git_workflow.main_branch ('$($config.MainBranch)')"
}

$currentBranch = Get-GitCurrentBranch -RootDir $rootDir
if ($currentBranch -ne $TargetBranch) {
    throw "checkout target branch '$TargetBranch' before merging; current branch is '$currentBranch'"
}

$targetStatus = Get-GitStatusAnalysis -RootDir $rootDir
if ($targetStatus.Lines.Count -gt 0) {
    throw "target branch worktree must be clean before merge: $TargetBranch"
}

$sourceHead = Get-GitBranchCommit -RootDir $rootDir -BranchName $SourceBranch
if ([string]::IsNullOrWhiteSpace($sourceHead)) {
    throw "source branch has no committed head to merge: $SourceBranch"
}

# Validate before mutating Git even when hooks have not been installed.
$state = Get-GitWorkflowState -RootDir $rootDir
$promotion = Get-LatestGitPromotion -State $state -SourceBranch $SourceBranch -SourceHead $sourceHead -TargetBranch $TargetBranch -Status 'authorized'
if ($null -eq $promotion) { throw 'merge requires an authorization for this exact source commit and target branch' }
if ($TargetBranch -eq $config.MainBranch) {
    $approval = Get-BoundGitApproval -State $state -RootDir $rootDir -ApprovalId $promotion.approval_id -SourceBranch $SourceBranch -SourceHead $sourceHead -TargetBranch $TargetBranch
    if ([string]::IsNullOrWhiteSpace($promotion.approval_id) -or $null -eq $approval) { throw 'merge requires a matching main approval' }
}

$previousPendingSourceBranch = [Environment]::GetEnvironmentVariable("CODEX_PENDING_MERGE_SOURCE_BRANCH", "Process")
$previousPendingSourceHead = [Environment]::GetEnvironmentVariable("CODEX_PENDING_MERGE_SOURCE_HEAD", "Process")
$mergeResult = $null

try {
    [Environment]::SetEnvironmentVariable("CODEX_PENDING_MERGE_SOURCE_BRANCH", $SourceBranch, "Process")
    [Environment]::SetEnvironmentVariable("CODEX_PENDING_MERGE_SOURCE_HEAD", $sourceHead, "Process")
    $mergeResult = Invoke-GitCommand -RootDir $rootDir -Arguments @("merge", "--no-ff", "--no-edit", $sourceHead) -AllowFailure
} finally {
    [Environment]::SetEnvironmentVariable("CODEX_PENDING_MERGE_SOURCE_BRANCH", $previousPendingSourceBranch, "Process")
    [Environment]::SetEnvironmentVariable("CODEX_PENDING_MERGE_SOURCE_HEAD", $previousPendingSourceHead, "Process")
}

if (-not $mergeResult.Success) {
    $mergeHead = Get-GitMergeHeadCommit -RootDir $rootDir
    if (-not [string]::IsNullOrWhiteSpace($mergeHead)) {
        Invoke-GitCommand -RootDir $rootDir -Arguments @("merge", "--abort") -AllowFailure | Out-Null
    }

    throw "authorized merge failed for $SourceBranch into $TargetBranch`n$($mergeResult.Output)"
}

$state = Get-GitWorkflowState -RootDir $rootDir
$targetHead = Get-GitHeadCommit -RootDir $rootDir
$auditIssues = Get-GitBranchAuditIssues -RootDir $rootDir -State $state -BranchName $TargetBranch -Commit $targetHead
if ($auditIssues.Count -gt 0) {
    throw "merged target branch failed workflow audit:`n- $($auditIssues -join ([Environment]::NewLine + "- "))"
}

Write-Output "merged_source: $SourceBranch"
Write-Output "merged_source_head: $sourceHead"
Write-Output "target_branch: $TargetBranch"
Write-Output "target_head: $targetHead"
