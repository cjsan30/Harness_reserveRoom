param(
    [string]$RepositoryRoot,
    [string]$Message = "bootstrap baseline",
    [string]$GateCommand = "",
    [switch]$DryRun,
    [switch]$Commit,
    [switch]$RequestApproval,
    [switch]$ApproveBootstrap,
    [string]$Approver = "operator",
    [switch]$Push,
    [string]$Remote = "origin",
    [string]$Branch = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
. (Join-Path $PSScriptRoot "git_workflow_common.ps1")

$rootDir = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Get-HarnessRoot -ScriptDirectory $PSScriptRoot
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}

if (-not $DryRun -and -not $Commit -and -not $RequestApproval -and -not $Push) {
    $DryRun = $true
}

function Test-BootstrapGeneratedPath {
    param([string]$Path)
    $normalized = ($Path -replace "\\", "/").Trim('"')
    # harness/reports/ holds runtime output but also engine templates that scripts
    # read (report_template.md, retry_prompt_template.md). Those must be committed;
    # excluding them leaves untracked files that make the bootstrap gate refuse.
    if ($normalized -match "^harness/reports/[^/]*_template\.md$") {
        return $false
    }
    foreach ($pattern in @(
            "^harness/reports/",
            "^harness/state/",
            "^harness/assignments/[^/]+/(inbox|in_progress|done)/",
            "^node_modules/",
            "^data/evaluation-logs\.jsonl$",
            "^\.env(\..*)?$"
        )) {
        if ($normalized -match $pattern) {
            return $true
        }
    }
    return $false
}

function Get-BootstrapStatusPath {
    param([string]$Line)
    if ($Line.Length -lt 4) {
        return ""
    }
    $path = $Line.Substring(3).Trim().Trim('"')
    if ($path -match " -> ") {
        $path = ($path -split " -> ")[-1]
    }
    return $path
}

Invoke-GitCommand -RootDir $rootDir -Arguments @("rev-parse", "--is-inside-work-tree") | Out-Null
$config = Get-GitWorkflowConfig -RootDir $rootDir
if ([string]::IsNullOrWhiteSpace($Branch)) {
    $Branch = $config.BootstrapBranch
}

$currentBranch = Get-GitCurrentBranch -RootDir $rootDir
if ($currentBranch -ne $Branch) {
    throw "bootstrap initial commit must run on '$Branch', current branch is '$currentBranch'"
}

$hasHead = Test-GitHeadExists -RootDir $rootDir
if ($hasHead -and -not $RequestApproval -and -not $Push) {
    throw "repository already has HEAD; use normal feature/final gate flow instead of bootstrap initial commit"
}

$auditScript = Join-Path $PSScriptRoot "audit_generated_artifacts.ps1"
$auditResult = Invoke-HarnessPowerShellFile -FilePath $auditScript -Arguments @("-RepositoryRoot", $rootDir) -AllowFailure
if (-not $auditResult.Success) {
    throw "generated artifact audit failed before bootstrap:`n$($auditResult.Output)"
}

$status = (Invoke-GitCommand -RootDir $rootDir -Arguments @("status", "--porcelain=v1", "--untracked-files=all")).Output
$candidateFiles = New-Object System.Collections.Generic.List[string]
foreach ($line in @($status -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    $path = Get-BootstrapStatusPath -Line $line
    if ([string]::IsNullOrWhiteSpace($path)) {
        continue
    }
    if (Test-BootstrapGeneratedPath -Path $path) {
        continue
    }
    $candidateFiles.Add($path) | Out-Null
}

if ($candidateFiles.Count -eq 0 -and -not $hasHead) {
    throw "no bootstrap candidate files were found after excluding generated artifacts"
}

$candidateLines = if ($candidateFiles.Count -eq 0) { "- none" } else { ($candidateFiles | ForEach-Object { "- $_" }) -join [Environment]::NewLine }
$plan = @"
# Bootstrap Initial Commit Plan

## Summary

- repository_root: $rootDir
- branch: $Branch
- dry_run: $([bool]$DryRun)
- commit_requested: $([bool]$Commit)
- request_approval: $([bool]$RequestApproval)
- approve_bootstrap: $([bool]$ApproveBootstrap)
- push_requested: $([bool]$Push)

## Candidate Files

$candidateLines
"@
$planPath = Get-HarnessConfiguredPath -RootDir $rootDir -Name "bootstrap_initial_commit_plan" -FallbackRelativePath "harness/reports/bootstrap_initial_commit_plan.md"
Write-Utf8File -Path $planPath -Content $plan

Write-Output "plan: $planPath"
Write-Output "candidate_count: $($candidateFiles.Count)"
if ($DryRun) {
    Write-Output "status: dry-run"
    exit 0
}

if ($Commit -and -not $hasHead) {
    foreach ($file in $candidateFiles) {
        Invoke-GitCommand -RootDir $rootDir -Arguments @("add", "--", $file) | Out-Null
    }

    $gateArgs = @("-Stage", "bootstrap", "-RepositoryRoot", $rootDir)
    if (-not [string]::IsNullOrWhiteSpace($GateCommand)) {
        $gateArgs += @("-Command", $GateCommand)
    }
    Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot "run_git_gate.ps1") -Arguments $gateArgs | Out-Null
    Invoke-GitCommand -RootDir $rootDir -Arguments @("commit", "-m", $Message) | Out-Null
    Write-Output "commit: created"
} elseif ($Commit -and $hasHead) {
    Write-Output "commit: skipped-existing-head"
}

$approvalId = ""
if ($RequestApproval -or $ApproveBootstrap) {
    $request = Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot "request_main_merge_approval.ps1") -Arguments @("-Bootstrap", "-Requester", $Approver, "-Reason", "bootstrap initial commit", "-RepositoryRoot", $rootDir)
    Write-Output $request.Output
    foreach ($line in @($request.Output -split "\r?\n")) {
        if ($line -match "^approval_id:\s*(.+)$") {
            $approvalId = $Matches[1].Trim()
        }
    }
}

if ($ApproveBootstrap) {
    if ([string]::IsNullOrWhiteSpace($approvalId)) {
        throw "approval id was not found after bootstrap approval request"
    }
    Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot "set_main_merge_approval.ps1") -Arguments @("-ApprovalId", $approvalId, "-Status", "approved", "-Approver", $Approver, "-Notes", "approved by bootstrap_initial_commit.ps1", "-RepositoryRoot", $rootDir) | Out-Null
    Write-Output "approval: approved"
}

if ($Push) {
    Invoke-GitCommand -RootDir $rootDir -Arguments @("push", "-u", $Remote, $Branch) | Out-Null
    Write-Output "push: complete"
}

Write-Output "status: complete"
