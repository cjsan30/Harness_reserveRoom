param(
    [string]$SourceBranch,
    [string]$TargetBranch,
    [string]$Title,
    [string]$BodyFile,
    [switch]$Draft,
    [switch]$SkipPush,
    [switch]$SkipAuthCheck,
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

$config = Get-GitWorkflowConfig -RootDir $rootDir
if ([string]::IsNullOrWhiteSpace($SourceBranch)) {
    $SourceBranch = Get-GitCurrentBranch -RootDir $rootDir
}
if ([string]::IsNullOrWhiteSpace($TargetBranch)) {
    $TargetBranch = $config.MainBranch
}
if ($TargetBranch -ne $config.MainBranch) {
    throw "PR candidate flow currently targets git_workflow.main_branch ('$($config.MainBranch)') only"
}

$branchInfo = Get-GitBranchDescriptor -RootDir $rootDir -BranchName $SourceBranch
if ($branchInfo.Kind -ne "test") {
    throw "main PR candidate must come from a dedicated test branch named like $($config.TestBranchPrefix)<candidate>"
}

$sourceHead = Get-GitBranchCommit -RootDir $rootDir -BranchName $SourceBranch
$sourceTree = Get-GitBranchTree -RootDir $rootDir -BranchName $SourceBranch
if ([string]::IsNullOrWhiteSpace($sourceHead) -or [string]::IsNullOrWhiteSpace($sourceTree)) {
    throw "source branch has no committed head: $SourceBranch"
}

$state = Get-GitWorkflowState -RootDir $rootDir
$finalGate = Get-LatestGitValidation -State $state -Branch $SourceBranch -Stage "final" -Status "pass" -TreeHash $sourceTree
if ($null -eq $finalGate) {
    throw "source branch is missing a passing final gate for tree $sourceTree"
}

$auditIssues = Get-GitBranchAuditIssues -RootDir $rootDir -State $state -BranchName $SourceBranch -Commit $sourceHead
if ($auditIssues.Count -gt 0) {
    throw "source branch failed workflow audit:`n- $($auditIssues -join ([Environment]::NewLine + "- "))"
}

if (-not $SkipAuthCheck) {
    Assert-GitHubCliAuthenticated -RootDir $rootDir
}

if (-not $SkipPush) {
    Invoke-GitCommand -RootDir $rootDir -Arguments @("push", "-u", "origin", $SourceBranch) | Out-Null
}

if ([string]::IsNullOrWhiteSpace($Title)) {
    $Title = "Harness candidate: $SourceBranch"
}

$reportsDir = Get-GitWorkflowResolvedPath -RootDir $rootDir -Name "reports_dir"
Ensure-HarnessDirectory -Path $reportsDir
$bodyPath = $BodyFile
if ([string]::IsNullOrWhiteSpace($bodyPath)) {
    $safeBranch = ($SourceBranch -replace "[^A-Za-z0-9_-]", "_")
    $bodyPath = Join-Path $reportsDir ("pr_body_" + $safeBranch + ".md")
    $body = @"
# Harness PR Candidate

## Summary

- source_branch: $SourceBranch
- source_head: $sourceHead
- source_tree: $sourceTree
- target_branch: $TargetBranch
- final_gate_report: $($finalGate.report)

## Local Gate

The source branch has a passing final gate for the exact tree hash above. GitHub Actions must still pass before merge.
"@
    Write-Utf8File -Path $bodyPath -Content $body
}

$existingPr = Get-GitHubPullRequestView -RootDir $rootDir -Selector $SourceBranch -AllowMissing
if ($null -ne $existingPr -and $existingPr.state -eq "OPEN") {
    $pr = $existingPr
} else {
    $arguments = @("pr", "create", "--base", $TargetBranch, "--head", $SourceBranch, "--title", $Title, "--body-file", $bodyPath)
    if ($Draft) {
        $arguments += "--draft"
    }
    Invoke-GitHubCli -RootDir $rootDir -Arguments $arguments | Out-Null
    $pr = Get-GitHubPullRequestView -RootDir $rootDir -Selector $SourceBranch
}

$reportContent = @"
# Pull Request Candidate

## Summary

- status: open
- number: $($pr.number)
- url: $($pr.url)
- source_branch: $SourceBranch
- source_head: $sourceHead
- target_branch: $TargetBranch
- final_gate_report: $($finalGate.report)
"@
$reportPath = Write-GitWorkflowReport -RootDir $rootDir -Prefix ("pr_candidate_" + ($SourceBranch -replace "[^A-Za-z0-9_-]", "_")) -Content $reportContent

Write-Output "pr_number: $($pr.number)"
Write-Output "pr_url: $($pr.url)"
Write-Output "source_branch: $SourceBranch"
Write-Output "source_head: $sourceHead"
Write-Output "report: $reportPath"
