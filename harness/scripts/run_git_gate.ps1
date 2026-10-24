param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("bootstrap", "feature", "integration", "final")]
    [string]$Stage,
    [string]$Owner,
    [string]$Command,
    [switch]$AllowWeakCommand,
    [switch]$AllowCommittedHead,
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

$branchInfo = Get-GitBranchDescriptor -RootDir $rootDir
$state = Get-GitWorkflowState -RootDir $rootDir
$requiresStagedChanges = ($Stage -eq "feature") -or (($Stage -eq "bootstrap") -and -not (Test-GitHeadExists -RootDir $rootDir))

$resolvedOwner = ""
$stageCommand = $Command
$stageSummary = ""

switch ($Stage) {
    "bootstrap" {
        if (-not $branchInfo.SupportsBootstrap) {
            throw "bootstrap gate is allowed only on $((Get-GitWorkflowConfig -RootDir $rootDir).BootstrapBranch)"
        }

        $resolvedOwner = "manager-harness"
        if ([string]::IsNullOrWhiteSpace($stageCommand)) {
            $stageCommand = Get-GitGateCommand -RootDir $rootDir -Stage "bootstrap"
        }
        $stageSummary = "Baseline bootstrap gate before the first protected main push."
    }
    "feature" {
        if ($branchInfo.Kind -ne "feature") {
            throw "feature gate requires a feature branch named like $((Get-GitWorkflowConfig -RootDir $rootDir).FeatureBranchPrefix)<owner>/<task> with an owner listed in the workflow policy"
        }

        if ([string]::IsNullOrWhiteSpace($Owner)) {
            $Owner = $branchInfo.Owner
        }

        if ($Owner -ne $branchInfo.Owner) {
            throw "feature gate owner does not match branch owner: expected $($branchInfo.Owner), got $Owner"
        }

        $resolvedOwner = $Owner
        if ([string]::IsNullOrWhiteSpace($stageCommand)) {
            $stageCommand = Get-GitGateCommand -RootDir $rootDir -Stage "feature" -Owner $Owner
        }
        $stageSummary = "Owner validation gate before commit or push from a feature branch."
    }
    "integration" {
        if ($branchInfo.Kind -ne "feature") {
            throw "integration gate requires a feature branch"
        }

        $resolvedOwner = "manager-main"
        if ([string]::IsNullOrWhiteSpace($stageCommand)) {
            $stageCommand = Get-GitGateCommand -RootDir $rootDir -Stage "integration"
        }
        $stageSummary = "Manager integration gate before authorizing promotion into dev."
    }
    "final" {
        if ($branchInfo.Kind -ne "test") {
            throw "final gate requires a dedicated test branch named like $((Get-GitWorkflowConfig -RootDir $rootDir).TestBranchPrefix)<candidate>"
        }

        $resolvedOwner = "manager-harness"
        if ([string]::IsNullOrWhiteSpace($stageCommand)) {
            $stageCommand = Get-GitGateCommand -RootDir $rootDir -Stage "final"
        }
        $stageSummary = "Full final gate on the dedicated test branch before main approval."
    }
}

if ([string]::IsNullOrWhiteSpace($stageCommand)) {
    throw "no command is configured for git gate stage '$Stage'"
}

if (-not $AllowWeakCommand) {
    $commandIssues = Get-HarnessValidationCommandIssues -CommandText $stageCommand
    if ($commandIssues.Count -gt 0) {
        throw "unsafe git gate command for stage '$Stage':`n- $($commandIssues -join ([Environment]::NewLine + "- "))"
    }
}

$candidateStatus = Assert-SealedGitCandidate -RootDir $rootDir -RequireStagedChanges:($requiresStagedChanges -and -not $AllowCommittedHead)
$treeHash = ""
$usedCommittedHead = $false
if ($requiresStagedChanges -and $AllowCommittedHead -and -not $candidateStatus.HasStagedChanges) {
    $treeHash = Get-GitHeadTree -RootDir $rootDir
    if ([string]::IsNullOrWhiteSpace($treeHash)) {
        throw "allowing a committed head requires an existing committed HEAD"
    }
    $usedCommittedHead = $true
} else {
    $treeHash = Get-GitIndexTree -RootDir $rootDir
}
$headCommit = Get-GitHeadCommit -RootDir $rootDir
$headTree = Get-GitHeadTree -RootDir $rootDir

$reportsDir = Get-GitWorkflowResolvedPath -RootDir $rootDir -Name "reports_dir"
Ensure-HarnessDirectory -Path $reportsDir
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
$safeBranch = ($branchInfo.Name -replace "[^A-Za-z0-9_-]", "_")
$logPath = Join-Path $reportsDir ($timestamp + "_" + $Stage + "_" + $safeBranch + ".log")
$previousActiveGateStage = [Environment]::GetEnvironmentVariable("CODEX_ACTIVE_GIT_GATE_STAGE", "Process")
try {
    [Environment]::SetEnvironmentVariable("CODEX_ACTIVE_GIT_GATE_STAGE", $Stage, "Process")
    $commandResult = Invoke-LoggedShellCommand -RootDir $rootDir -CommandText $stageCommand -LogPath $logPath
} finally {
    [Environment]::SetEnvironmentVariable("CODEX_ACTIVE_GIT_GATE_STAGE", $previousActiveGateStage, "Process")
}
$status = if ($commandResult.Success) { "pass" } else { "fail" }

$validationRecord = [pscustomobject]@{
    id = New-GitWorkflowRecordId -Prefix "validation"
    branch = $branchInfo.Name
    branch_kind = $branchInfo.Kind
    owner = $resolvedOwner
    stage = $Stage
    status = $status
    command = $stageCommand
    tree_hash = $treeHash
    head_commit = $headCommit
    head_tree = $headTree
    staged_changes = $candidateStatus.HasStagedChanges
    executed_at = (Get-Date).ToString("o")
    log = ""
    report = ""
}

$reportContent = @"
# Git Gate Report

## Summary

- stage: $Stage
- status: $status
- branch: $($branchInfo.Name)
- branch_kind: $($branchInfo.Kind)
- owner: $resolvedOwner
- tree_hash: $treeHash
- head_commit_before_gate: $(if ([string]::IsNullOrWhiteSpace($headCommit)) { "none" } else { $headCommit })
- committed_head_mode: $(if ($usedCommittedHead) { "true" } else { "false" })

## Purpose

$stageSummary

## Command

`$ $stageCommand`

## Candidate

- staged_changes_present: $($candidateStatus.HasStagedChanges)
- committed_head_mode: $(if ($usedCommittedHead) { "true" } else { "false" })
- log: $(Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $logPath)

## Next

$(if ($status -eq "pass") { "The branch content for this tree hash is approved for the next workflow step." } else { "Fix the failure, reseal the candidate tree, and rerun this gate." })
"@

$reportPath = Write-GitWorkflowReport -RootDir $rootDir -Prefix ($Stage + "_" + $safeBranch) -Content $reportContent
$validationRecord.log = Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $logPath
$validationRecord.report = Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $reportPath

$state.validations = @($state.validations) + $validationRecord
Save-GitWorkflowState -RootDir $rootDir -State $state | Out-Null

Write-Output "git gate stage: $Stage"
Write-Output "status: $status"
Write-Output "branch: $($branchInfo.Name)"
Write-Output "tree_hash: $treeHash"
Write-Output "report: $reportPath"
Write-Output "log: $logPath"

if (-not $commandResult.Success) {
    exit 1
}
