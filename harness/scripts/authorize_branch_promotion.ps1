param(
	[Parameter(Mandatory = $true)]
	[string]$SourceBranch,
	[Parameter(Mandatory = $true)]
	[string]$TargetBranch,
    [string]$ApprovalId,
    [string]$AuthorizedBy = "operator",
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
if ($TargetBranch -ne $config.DevBranch -and $TargetBranch -ne $config.MainBranch) {
    throw "target branch must match git_workflow.dev_branch ('$($config.DevBranch)') or git_workflow.main_branch ('$($config.MainBranch)')"
}

$state = Get-GitWorkflowState -RootDir $rootDir
$branchInfo = Get-GitBranchDescriptor -RootDir $rootDir -BranchName $SourceBranch
$sourceHead = Get-GitBranchCommit -RootDir $rootDir -BranchName $SourceBranch
$sourceTree = Get-GitBranchTree -RootDir $rootDir -BranchName $SourceBranch

if ([string]::IsNullOrWhiteSpace($sourceHead) -or [string]::IsNullOrWhiteSpace($sourceTree)) {
    throw "source branch has no committed head to authorize: $SourceBranch"
}

$requiredStages = @()
$approvalRecord = $null

if ($TargetBranch -eq $config.DevBranch) {
    if ($branchInfo.Kind -ne "feature") {
        throw "promotion into dev is allowed only from a feature branch"
    }

    $requiredStages = @("feature", "integration")
    foreach ($stageName in $requiredStages) {
        $validation = Get-LatestGitValidation -State $state -Branch $SourceBranch -Stage $stageName -Status "pass" -TreeHash $sourceTree
        if ($null -eq $validation) {
            throw "missing passing $stageName gate for $SourceBranch at tree $sourceTree"
        }
    }
}

if ($TargetBranch -eq $config.MainBranch) {
    if ($branchInfo.Kind -ne "test") {
        throw "promotion into main is allowed only from a dedicated test branch"
    }

    $requiredStages = @("final")
    $finalValidation = Get-LatestGitValidation -State $state -Branch $SourceBranch -Stage "final" -Status "pass" -TreeHash $sourceTree
    if ($null -eq $finalValidation) {
        throw "missing passing final gate for $SourceBranch at tree $sourceTree"
    }

    $approvalRecord = Get-BoundGitApproval -State $state -RootDir $rootDir -ApprovalId $ApprovalId -SourceBranch $SourceBranch -SourceHead $sourceHead -TargetBranch $TargetBranch

    if ($null -eq $approvalRecord) {
        throw "an approved main merge approval is required before authorizing promotion into main"
    }
}

$existingPromotion = Get-LatestGitPromotion -State $state -SourceBranch $SourceBranch -SourceHead $sourceHead -TargetBranch $TargetBranch -Status "authorized"
if ($null -ne $existingPromotion) {
    $existingReport = Resolve-ProjectPath -RootDir $rootDir -ProjectPath $existingPromotion.report -Label "promotion.report"
    Write-Output "promotion_id: $($existingPromotion.id)"
    Write-Output "status: authorized"
    Write-Output "report: $existingReport"
    exit 0
}

$promotionRecord = [pscustomobject]@{
    id = New-GitWorkflowRecordId -Prefix "promotion"
    source_branch = $SourceBranch
    source_head = $sourceHead
    source_tree = $sourceTree
    target_branch = $TargetBranch
    status = "authorized"
    required_stages = $requiredStages
    approval_id = $(if ($null -eq $approvalRecord) { "" } else { $approvalRecord.id })
    authorized_by = $AuthorizedBy
    authorized_at = (Get-Date).ToString("o")
    report = ""
}

$stageLines = if ($requiredStages.Count -eq 0) { "- none" } else { ($requiredStages | ForEach-Object { "- $_" }) -join [Environment]::NewLine }
$reportContent = @"
# Branch Promotion Authorization

## Summary

- promotion_id: $($promotionRecord.id)
- source_branch: $SourceBranch
- source_head: $sourceHead
- target_branch: $TargetBranch
- authorized_by: $AuthorizedBy
- approval_id: $(if ([string]::IsNullOrWhiteSpace($promotionRecord.approval_id)) { "none" } else { $promotionRecord.approval_id })

## Required Stages

$stageLines

## Use

This authorization unlocks a protected merge hook for the exact source head above.
"@

$reportPath = Write-GitWorkflowReport -RootDir $rootDir -Prefix ("promotion_" + ($SourceBranch -replace "[^A-Za-z0-9_-]", "_") + "_" + $TargetBranch) -Content $reportContent
$promotionRecord.report = Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $reportPath

$state.promotions = @($state.promotions) + $promotionRecord
Save-GitWorkflowState -RootDir $rootDir -State $state | Out-Null

Write-Output "promotion_id: $($promotionRecord.id)"
Write-Output "status: authorized"
Write-Output "report: $reportPath"
