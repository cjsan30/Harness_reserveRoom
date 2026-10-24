param(
    [Parameter(Mandatory = $true)]
    [string]$ApprovalId,
    [Parameter(Mandatory = $true)]
    [ValidateSet("approved", "rejected")]
    [string]$Status,
    [Parameter(Mandatory = $true)]
    [string]$Approver,
    [string]$Notes = "",
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
$approvalRecord = Get-GitApprovalRecord -State $state -ApprovalId $ApprovalId
if ($null -eq $approvalRecord) {
    throw "approval record not found: $ApprovalId"
}

if ($Status -eq 'approved') {
    $config = Get-GitWorkflowConfig -RootDir $rootDir
    $head = Get-GitBranchCommit -RootDir $rootDir -BranchName $approvalRecord.source_branch
    $tree = Get-GitBranchTree -RootDir $rootDir -BranchName $approvalRecord.source_branch
    $branch = Get-GitBranchDescriptor -RootDir $rootDir -BranchName $approvalRecord.source_branch
    $expectedStage = if ($approvalRecord.stage -eq 'bootstrap' -and $branch.SupportsBootstrap) { 'bootstrap' } elseif ($branch.Kind -eq 'test') { 'final' } else { throw 'approval source is not a permitted branch' }
    $bound = Get-BoundGitApproval -State $state -RootDir $rootDir -ApprovalId $ApprovalId -SourceBranch $approvalRecord.source_branch -SourceHead $head -TargetBranch $config.MainBranch -Stage $expectedStage -Status ''
    $validation = Get-LatestGitValidation -State $state -Branch $approvalRecord.source_branch -Stage $expectedStage -Status 'pass' -TreeHash $tree
    if ($null -eq $bound -or $null -eq $validation -or $approvalRecord.source_tree -cne $tree) {
        throw 'approval scope or validation changed; request a new approval for the current commit'
    }
}

$approvalRecord.status = $Status
$approvalRecord.approver = $Approver
$approvalRecord.decided_at = (Get-Date).ToString("o")
$approvalRecord.notes = $(if ([string]::IsNullOrWhiteSpace($Notes)) { "none" } else { $Notes })

$reportContent = @"
# Main Merge Approval Decision

## Summary

- approval_id: $ApprovalId
- status: $Status
- approver: $Approver
- source_branch: $($approvalRecord.source_branch)
- source_head: $($approvalRecord.source_head)
- decided_at: $($approvalRecord.decided_at)

## Notes

$(if ([string]::IsNullOrWhiteSpace($Notes)) { "No notes were provided." } else { $Notes })
"@

$reportPath = Write-GitWorkflowReport -RootDir $rootDir -Prefix ("approval_decision_" + ($ApprovalId -replace "[^A-Za-z0-9_-]", "_")) -Content $reportContent
$approvalRecord.report = Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $reportPath

Save-GitWorkflowState -RootDir $rootDir -State $state | Out-Null

Write-Output "approval_id: $ApprovalId"
Write-Output "status: $Status"
Write-Output "report: $reportPath"
