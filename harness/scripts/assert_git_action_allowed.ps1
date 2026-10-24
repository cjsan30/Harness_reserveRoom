param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("commit", "push", "merge", "rebase")]
    [string]$Action,
    [string]$RemoteName = "",
    [string]$RemoteUrl = "",
    [string]$RefUpdateFile = "",
    [string]$BranchName = "",
    [string]$UpstreamRef = "",
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

$policyRoot = [Environment]::GetEnvironmentVariable("CODEX_HARNESS_ROOT", "Process")
if ([string]::IsNullOrWhiteSpace($policyRoot)) {
    $policyRoot = Get-HarnessRoot -ScriptDirectory $PSScriptRoot
} else {
    $policyRoot = [System.IO.Path]::GetFullPath($policyRoot)
}

# Hook validation must inspect the repository/worktree that triggered the hook,
# not any outer harness workspace carried in the environment.
[Environment]::SetEnvironmentVariable("CODEX_GIT_WORKSPACE_ROOT", $rootDir, "Process")
$pendingMergeSourceBranch = [Environment]::GetEnvironmentVariable("CODEX_PENDING_MERGE_SOURCE_BRANCH", "Process")
$pendingMergeSourceHead = [Environment]::GetEnvironmentVariable("CODEX_PENDING_MERGE_SOURCE_HEAD", "Process")

function Deny-GitAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Error $Message
    exit 1
}

function Assert-BranchHeadAuthorized {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BranchToCheck,
        [Parameter(Mandatory = $true)]
        [string]$CommitToCheck
    )

    $issues = Get-GitBranchAuditIssues -RootDir $rootDir -State $state -BranchName $BranchToCheck -Commit $CommitToCheck
    if ($issues.Count -gt 0) {
        Deny-GitAction ($issues -join [Environment]::NewLine)
    }
}

function Assert-ProtectedMergeSourceAuthorized {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetBranch,
        [Parameter(Mandatory = $true)]
        [string]$SourceHead
    )

    $targetInfo = Get-GitBranchDescriptor -RootDir $policyRoot -BranchName $TargetBranch
    if ($targetInfo.Kind -notin @("dev", "main")) {
        return
    }

    $promotion = Get-LatestGitPromotion -State $state -SourceHead $SourceHead -TargetBranch $TargetBranch -Status "authorized"
    if ($null -eq $promotion) {
        Deny-GitAction "protected merge is missing an authorized promotion for source head $SourceHead into $TargetBranch"
    }

    if ($targetInfo.Kind -eq "main") {
        if ([string]::IsNullOrWhiteSpace($promotion.approval_id)) {
            Deny-GitAction "protected merge into main requires an approval-linked promotion for source head $SourceHead"
        }

        $approval = Get-BoundGitApproval -State $state -RootDir $policyRoot -ApprovalId $promotion.approval_id -SourceBranch $promotion.source_branch -SourceHead $SourceHead -TargetBranch $TargetBranch
        if ($null -eq $approval) {
            Deny-GitAction "protected merge into main is missing an approved main merge approval for source head $SourceHead"
        }
    }
}

function Assert-ProtectedMergeBranchAuthorized {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetBranch,
        [Parameter(Mandatory = $true)]
        [string]$SourceBranch
    )

    $sourceHead = Get-GitBranchCommit -RootDir $rootDir -BranchName $SourceBranch
    if ([string]::IsNullOrWhiteSpace($sourceHead)) {
        Deny-GitAction "protected merge could not resolve source branch head for $SourceBranch"
    }

    Assert-ProtectedMergeSourceAuthorized -TargetBranch $TargetBranch -SourceHead $sourceHead
}

# Remote feature/test branches may be deleted once their remote head is already
# contained in dev or main, or with a user-recorded deletion approval for that
# exact head. main and dev are never deletable.
function Assert-PushDeleteAllowed {
    param(
        [Parameter(Mandatory = $true)]
        $Update
    )

    if ([string]::IsNullOrWhiteSpace($Update.RemoteBranch)) {
        Deny-GitAction "deleting non-branch refs is blocked: $($Update.RemoteRef)"
    }

    $targetInfo = Get-GitBranchDescriptor -RootDir $policyRoot -BranchName $Update.RemoteBranch
    if ($targetInfo.Kind -notin @("feature", "test")) {
        Deny-GitAction "branch deletion is allowed only for merged feature or test branches: $($Update.RemoteBranch)"
    }

    if (Test-GitZeroObjectId -Sha $Update.RemoteSha) {
        Deny-GitAction "branch deletion could not resolve the remote head of $($Update.RemoteBranch)"
    }

    $containers = New-Object System.Collections.Generic.List[string]
    foreach ($protectedBranch in @($config.DevBranch, $config.MainBranch)) {
        $containers.Add("refs/heads/$protectedBranch") | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($RemoteName)) {
            $containers.Add("refs/remotes/$RemoteName/$protectedBranch") | Out-Null
        }
    }

    foreach ($container in $containers) {
        $exists = Invoke-HarnessProcess -Executable "git" -Arguments @("-C", $rootDir, "rev-parse", "--verify", "--quiet", $container) -AllowFailure
        if (-not $exists.Success) {
            continue
        }

        $merged = Invoke-HarnessProcess -Executable "git" -Arguments @("-C", $rootDir, "merge-base", "--is-ancestor", $Update.RemoteSha, $container) -AllowFailure
        if ($merged.Success) {
            return
        }
    }

    # Unmerged work (abandoned or restarted tasks) needs an explicit user approval
    # bound to this exact remote head.
    $approval = Get-GitDeletionApproval -State $state -RootDir $rootDir -Branch $Update.RemoteBranch -Head $Update.RemoteSha -RemoteName $RemoteName
    if ($null -ne $approval) {
        return
    }

    Deny-GitAction ("branch deletion is blocked: $($Update.RemoteBranch) is not merged into $($config.DevBranch) or $($config.MainBranch). " +
        "If the user wants it deleted, record the approval first: approve_branch_deletion.ps1 -Branch $($Update.RemoteBranch) -Approver <name>")
}

function Assert-PushUpdateAllowed {
    param(
        [Parameter(Mandatory = $true)]
        $Update
    )

    if ($Update.IsDelete) {
        Assert-PushDeleteAllowed -Update $Update
        return
    }

    if ([string]::IsNullOrWhiteSpace($Update.RemoteBranch)) {
        Deny-GitAction "pushing non-branch refs is blocked: $($Update.RemoteRef)"
    }

    if ([string]::IsNullOrWhiteSpace($Update.LocalBranch)) {
        Deny-GitAction "branch pushes must come from a named local branch, not an arbitrary refspec: $($Update.LocalRef) -> $($Update.RemoteRef)"
    }

    $targetInfo = Get-GitBranchDescriptor -RootDir $rootDir -BranchName $Update.RemoteBranch
    if ($targetInfo.Kind -eq "unknown") {
        Deny-GitAction "push target does not match the approved workflow naming rules: $($Update.RemoteBranch)"
    }

    if ($targetInfo.Kind -in @("main", "dev")) {
        if ($Update.LocalBranch -ne $Update.RemoteBranch) {
            Deny-GitAction "protected branches must be updated from the matching local branch after a local merge: $($Update.LocalBranch) -> $($Update.RemoteBranch)"
        }

        Assert-BranchHeadAuthorized -BranchToCheck $Update.RemoteBranch -CommitToCheck $Update.LocalSha
        return
    }

    if ($targetInfo.Kind -in @("feature", "test")) {
        if ($Update.LocalBranch -ne $Update.RemoteBranch) {
            Deny-GitAction "branch refspec rewriting is blocked for $($Update.RemoteBranch); push the matching local branch instead"
        }

        Assert-BranchHeadAuthorized -BranchToCheck $Update.RemoteBranch -CommitToCheck $Update.LocalSha
        return
    }

    Deny-GitAction "push target is not covered by the approved workflow: $($Update.RemoteBranch)"
}

$config = Get-GitWorkflowConfig -RootDir $policyRoot
$state = Get-GitWorkflowState -RootDir $policyRoot
$branchInfo = Get-GitBranchDescriptor -RootDir $policyRoot -BranchName (Get-GitCurrentBranch -RootDir $rootDir)
$headExists = Test-GitHeadExists -RootDir $rootDir

switch ($Action) {
    "commit" {
        # Commits on working branches are local and free. Evidence is required where
        # work leaves the branch: feature push (feature gate), dev merge (integration
        # gate + promotion) and main merge (final gate + approval).
        if ($branchInfo.Kind -notin @("main", "dev", "test")) {
            exit 0
        }

        if ($branchInfo.SupportsBootstrap -and -not $headExists) {
            try {
                Assert-SealedGitCandidate -RootDir $rootDir -RequireStagedChanges | Out-Null
            } catch {
                Deny-GitAction $_.Exception.Message
            }

            $treeHash = Get-GitIndexTree -RootDir $rootDir
            $validation = Get-LatestGitValidation -State $state -Branch $branchInfo.Name -Stage "bootstrap" -Status "pass" -TreeHash $treeHash
            if ($null -eq $validation) {
                Deny-GitAction "the first protected commit requires a passing bootstrap gate for the exact staged tree. Run: pwsh -NoProfile -File harness/scripts/run_git_gate.ps1 -Stage bootstrap"
            }

            exit 0
        }

        Deny-GitAction "direct commits are blocked on '$($branchInfo.Name)'. Use a feature branch, or use the bootstrap flow only for the first protected commit."
    }
    "push" {
        $refUpdates = Get-GitPushRefUpdates -RefUpdateFile $RefUpdateFile
        if (@($refUpdates).Count -gt 0) {
            foreach ($update in @($refUpdates)) {
                Assert-PushUpdateAllowed -Update $update
            }

            exit 0
        }

        if (-not $headExists) {
            Deny-GitAction "push is blocked because the current branch has no committed HEAD"
        }

        Assert-BranchHeadAuthorized -BranchToCheck $branchInfo.Name -CommitToCheck (Get-GitHeadCommit -RootDir $rootDir)
        exit 0
    }
    "merge" {
        if ($branchInfo.Name -ne $config.DevBranch -and $branchInfo.Name -ne $config.MainBranch) {
            exit 0
        }

        if (-not [string]::IsNullOrWhiteSpace($pendingMergeSourceHead)) {
            Assert-ProtectedMergeSourceAuthorized -TargetBranch $branchInfo.Name -SourceHead $pendingMergeSourceHead
            exit 0
        }

        if (-not [string]::IsNullOrWhiteSpace($pendingMergeSourceBranch)) {
            Assert-ProtectedMergeBranchAuthorized -TargetBranch $branchInfo.Name -SourceBranch $pendingMergeSourceBranch
            exit 0
        }

        $mergeHead = Get-GitPendingMergeHeadCommit -RootDir $rootDir
        if (-not [string]::IsNullOrWhiteSpace($mergeHead)) {
            Assert-ProtectedMergeSourceAuthorized -TargetBranch $branchInfo.Name -SourceHead ([string]$mergeHead)
            exit 0
        }

        $mergeSourceBranch = Get-GitPendingMergeSourceBranch -RootDir $rootDir
        if (-not [string]::IsNullOrWhiteSpace($mergeSourceBranch)) {
            Assert-ProtectedMergeBranchAuthorized -TargetBranch $branchInfo.Name -SourceBranch $mergeSourceBranch
            exit 0
        }

        Deny-GitAction "protected merge could not resolve MERGE_HEAD"
        exit 0
    }
    "rebase" {
        $targetBranch = $BranchName
        if ([string]::IsNullOrWhiteSpace($targetBranch)) {
            $targetBranch = $branchInfo.Name
        }

        $targetInfo = Get-GitBranchDescriptor -RootDir $rootDir -BranchName $targetBranch
        if ($targetInfo.Kind -in @("main", "dev", "test")) {
            Deny-GitAction "rebasing protected branches is blocked: $targetBranch"
        }

        if ($targetInfo.SupportsBootstrap) {
            Deny-GitAction "rebasing the bootstrap branch is blocked: $targetBranch"
        }

        exit 0
    }
}
