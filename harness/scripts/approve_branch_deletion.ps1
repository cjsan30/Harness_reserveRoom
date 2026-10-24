param(
    [Parameter(Mandatory = $true)]
    [string]$Branch,
    [Parameter(Mandatory = $true)]
    [string]$Approver,
    [string]$RemoteName = "origin",
    [string]$Head = "",
    [string]$Reason = "",
    [string]$RepositoryRoot
)

# Records the user's approval to delete an unmerged remote feature/test branch
# (abandoned or restarted work). The pre-push hook then allows deleting exactly
# that branch at exactly that remote head. main and dev cannot be approved.

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
. (Join-Path $PSScriptRoot "git_workflow_common.ps1")

$rootDir = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Get-HarnessRoot -ScriptDirectory $PSScriptRoot
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}

$branchInfo = Get-GitBranchDescriptor -RootDir $rootDir -BranchName $Branch
if ($branchInfo.Kind -notin @("feature", "test")) {
    throw "only feature or test branches can be approved for deletion: $Branch ($($branchInfo.Kind))"
}

if ([string]::IsNullOrWhiteSpace($Head)) {
    $remoteRef = "refs/remotes/$RemoteName/$Branch"
    $resolved = Invoke-HarnessProcess -Executable "git" -Arguments @("-C", $rootDir, "rev-parse", "--verify", "--quiet", $remoteRef) -AllowFailure
    if (-not $resolved.Success -or [string]::IsNullOrWhiteSpace($resolved.Output)) {
        throw "cannot resolve $remoteRef; fetch the remote first or pass -Head <remote-sha>"
    }
    $Head = $resolved.Output.Trim()
}

if ($Head -notmatch "^[0-9a-fA-F]{40}$") {
    throw "-Head must be a full 40-character commit id"
}

$state = Get-GitWorkflowState -RootDir $rootDir
$record = [pscustomobject]@{
    id = New-GitWorkflowRecordId -Prefix "deletion"
    status = "approved"
    repository_root = $rootDir
    remote = $RemoteName
    branch = $Branch
    head = $Head.ToLowerInvariant()
    approver = $Approver
    reason = $(if ([string]::IsNullOrWhiteSpace($Reason)) { "none" } else { $Reason })
    approved_at = (Get-Date).ToString("o")
    report = ""
}

$reportContent = @"
# Branch Deletion Approval

## Summary

- approval_id: $($record.id)
- branch: $Branch
- remote: $RemoteName
- head: $($record.head)
- approver: $Approver
- approved_at: $($record.approved_at)

## Reason

$($record.reason)
"@

$reportPath = Write-GitWorkflowReport -RootDir $rootDir -Prefix ("branch_deletion_" + ($Branch -replace "[^A-Za-z0-9_-]", "_")) -Content $reportContent
$record.report = Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $reportPath
$state.deletion_approvals = @($state.deletion_approvals) + @($record)
Save-GitWorkflowState -RootDir $rootDir -State $state | Out-Null

Write-Output "deletion_approval_id: $($record.id)"
Write-Output "branch: $Branch"
Write-Output "head: $($record.head)"
Write-Output "next: git push $RemoteName --delete $Branch"
Write-Output "report: $reportPath"
