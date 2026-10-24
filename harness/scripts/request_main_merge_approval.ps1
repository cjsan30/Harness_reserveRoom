param(
    [string]$SourceBranch,
    [switch]$Bootstrap,
    [string]$Requester = "operator",
    [string]$Reason = "",
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

if ([string]::IsNullOrWhiteSpace($SourceBranch)) {
    $SourceBranch = Get-GitCurrentBranch -RootDir $rootDir
}

$branchInfo = Get-GitBranchDescriptor -RootDir $rootDir -BranchName $SourceBranch
$state = Get-GitWorkflowState -RootDir $rootDir
$sourceHead = Get-GitBranchCommit -RootDir $rootDir -BranchName $SourceBranch
$sourceTree = Get-GitBranchTree -RootDir $rootDir -BranchName $SourceBranch

if ([string]::IsNullOrWhiteSpace($sourceHead) -or [string]::IsNullOrWhiteSpace($sourceTree)) {
    throw "source branch has no committed head to request approval for: $SourceBranch"
}

$requiredStage = "final"
if ($Bootstrap) {
    if (-not $branchInfo.SupportsBootstrap) {
        throw "bootstrap approval can be requested only from $((Get-GitWorkflowConfig -RootDir $rootDir).BootstrapBranch)"
    }

    $requiredStage = "bootstrap"
} elseif ($branchInfo.Kind -ne "test") {
    throw "main merge approval requires a dedicated test branch"
}

$validation = Get-LatestGitValidation -State $state -Branch $SourceBranch -Stage $requiredStage -Status "pass" -TreeHash $sourceTree
if ($null -eq $validation) {
    throw "no passing $requiredStage gate exists for $SourceBranch at tree $sourceTree"
}

$existingApproval = Get-BoundGitApproval -State $state -RootDir $rootDir -SourceBranch $SourceBranch -SourceHead $sourceHead -TargetBranch (Get-GitWorkflowConfig -RootDir $rootDir).MainBranch -Stage $requiredStage -Status ''
if ($null -ne $existingApproval -and @("requested", "approved") -contains $existingApproval.status) {
    $existingReport = Resolve-ProjectPath -RootDir $rootDir -ProjectPath $existingApproval.report -Label "approval.report"
    Write-Output "approval_id: $($existingApproval.id)"
    Write-Output "status: $($existingApproval.status)"
    Write-Output "report: $existingReport"
    exit 0
}

$approvalRecord = [pscustomobject]@{
    id = New-GitWorkflowRecordId -Prefix "approval"
    repository_root = [IO.Path]::GetFullPath($rootDir).TrimEnd((Get-HarnessPathTrimChars))
    source_branch = $SourceBranch
    source_head = $sourceHead
    source_tree = $sourceTree
    target_branch = (Get-GitWorkflowConfig -RootDir $rootDir).MainBranch
    stage = $requiredStage
    status = "requested"
    requester = $Requester
    approver = ""
    requested_at = (Get-Date).ToString("o")
    decided_at = ""
    reason = $(if ([string]::IsNullOrWhiteSpace($Reason)) { "none" } else { $Reason })
    notes = ""
    report = ""
}

$reportContent = @"
# Main Merge Approval Request

## Summary

- approval_id: $($approvalRecord.id)
- status: requested
- source_branch: $SourceBranch
- source_head: $sourceHead
- source_tree: $sourceTree
- required_stage: $requiredStage
- requester: $Requester

## Reason

$(if ([string]::IsNullOrWhiteSpace($Reason)) { "No extra reason was provided." } else { $Reason })

## Required Action

Review the candidate branch, confirm the latest gate is sufficient, and then approve or reject with:

pwsh -NoProfile -File harness/scripts/set_main_merge_approval.ps1 -ApprovalId $($approvalRecord.id) -Status approved -Approver <name>
"@

$reportPath = Write-GitWorkflowReport -RootDir $rootDir -Prefix ("approval_request_" + ($SourceBranch -replace "[^A-Za-z0-9_-]", "_")) -Content $reportContent
$approvalRecord.report = Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $reportPath

$state.approvals = @($state.approvals) + $approvalRecord
Save-GitWorkflowState -RootDir $rootDir -State $state | Out-Null

Write-Output "approval_id: $($approvalRecord.id)"
Write-Output "status: requested"
Write-Output "report: $reportPath"
