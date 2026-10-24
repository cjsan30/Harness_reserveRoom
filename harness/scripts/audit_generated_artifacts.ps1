param(
    [string]$RepositoryRoot,
    [switch]$WarnOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
. (Join-Path $PSScriptRoot "git_workflow_common.ps1")

$rootDir = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Get-HarnessRoot -ScriptDirectory $PSScriptRoot
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}

$issues = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-GeneratedIssue {
    param([string]$Message)
    $issues.Add($Message) | Out-Null
}

function Add-GeneratedWarning {
    param([string]$Message)
    $warnings.Add($Message) | Out-Null
}

function Test-HarnessGeneratedPath {
    param([string]$Path)

    $normalized = ($Path -replace "\\", "/").Trim('"')
    foreach ($pattern in @(
            "^reports/logs/",
            "^reports/test_results/",
            "^reports/retry_prompts/",
            "^reports/seed_plans/",
            "^reports/dispatch_packets/",
            "^reports/agent_runs/",
            "^reports/git_workflow/",
            "^reports/latest_report\.md$",
            "^reports/preflight_report\.md$",
            "^reports/status\.md$",
            "^reports/status\.json$",
            "^reports/sensitive_followups\.md$",
            "^reports/live_dispatch_log\.md$",
            "^reports/dispatch_log\.md$",
            "^reports/seed_dispatch_log\.md$",
            "^reports/assignment_log\.md$",
            "^reports/notifications_log\.md$",
            "^reports/generated_artifacts_audit\.md$",
            "^reports/porting_layout_audit\.md$",
            "^reports/git_remote_auth_audit\.md$",
            "^reports/bootstrap_initial_commit_plan\.md$",
            "^state/locks/",
            "^state/worktrees/",
            "^state/git_workflow/",
            "^state/notifications/",
            "^assignments/[^/]+/(inbox|in_progress|done)/",
            "^harness/reports/logs/",
            "^harness/reports/test_results/",
            "^harness/reports/retry_prompts/",
            "^harness/reports/seed_plans/",
            "^harness/reports/dispatch_packets/",
            "^harness/reports/agent_runs/",
            "^harness/reports/git_workflow/",
            "^harness/reports/latest_report\.md$",
            "^harness/reports/preflight_report\.md$",
            "^harness/reports/status\.md$",
            "^harness/reports/status\.json$",
            "^harness/reports/sensitive_followups\.md$",
            "^harness/reports/live_dispatch_log\.md$",
            "^harness/reports/dispatch_log\.md$",
            "^harness/reports/seed_dispatch_log\.md$",
            "^harness/reports/assignment_log\.md$",
            "^harness/reports/notifications_log\.md$",
            "^harness/reports/generated_artifacts_audit\.md$",
            "^harness/reports/porting_layout_audit\.md$",
            "^harness/reports/git_remote_auth_audit\.md$",
            "^harness/state/locks/",
            "^harness/state/worktrees/",
            "^harness/state/git_workflow/",
            "^harness/state/notifications/",
            "^harness/assignments/[^/]+/(inbox|in_progress|done)/"
        )) {
        if ($normalized -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-GitStatusPath {
    param([string]$Line)

    if ($Line.Length -lt 4) {
        return ""
    }

    $path = $Line.Substring(3).Trim()
    if ($path -match " -> ") {
        $path = ($path -split " -> ")[-1]
    }
    return $path.Trim('"')
}

try {
    Invoke-GitCommand -RootDir $rootDir -Arguments @("rev-parse", "--is-inside-work-tree") | Out-Null
} catch {
    Add-GeneratedWarning "repository is not a Git worktree; generated artifact staging audit skipped"
}

$stagedGenerated = @()
$unstagedGenerated = @()
$untrackedGenerated = @()

if ($warnings.Count -eq 0) {
    $status = (Invoke-GitCommand -RootDir $rootDir -Arguments @("status", "--porcelain=v1", "--untracked-files=all")).Output
    foreach ($line in @($status -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if ($line.Length -lt 3) {
            continue
        }

        $xy = $line.Substring(0, 2)
        $path = Get-GitStatusPath -Line $line
        if (-not (Test-HarnessGeneratedPath -Path $path)) {
            continue
        }

        if ($xy -eq "??") {
            $untrackedGenerated += $path
            continue
        }

        if ($xy[0] -ne ' ') {
            $stagedGenerated += $path
        }
        if ($xy[1] -ne ' ') {
            $unstagedGenerated += $path
        }
    }
}

foreach ($path in $stagedGenerated) {
    $message = "generated artifact is staged and can invalidate gate sealing: $path"
    if ($WarnOnly) {
        Add-GeneratedWarning $message
    } else {
        Add-GeneratedIssue $message
    }
}
foreach ($path in $unstagedGenerated) {
    Add-GeneratedWarning "generated artifact has unstaged changes: $path"
}
foreach ($path in $untrackedGenerated) {
    Add-GeneratedWarning "generated artifact is untracked; ensure .gitignore includes the harness generated-artifact template: $path"
}

$gitIgnorePath = Join-Path $rootDir ".gitignore"
if (-not (Test-Path -LiteralPath $gitIgnorePath)) {
    Add-GeneratedIssue ".gitignore is missing; generated harness reports/state may enter the candidate tree"
} else {
    $gitIgnore = Get-Content -Raw -LiteralPath $gitIgnorePath
    foreach ($requiredEntry in @(
            "harness/reports/logs/",
            "harness/reports/test_results/",
            "harness/reports/git_workflow/",
            "harness/reports/latest_report.md",
            "harness/reports/preflight_report.md",
            "harness/reports/generated_artifacts_audit.md",
            "harness/state/git_workflow/",
            "harness/state/worktrees/",
            "harness/assignments/*/inbox/*.md"
        )) {
        if ($gitIgnore -notmatch [Regex]::Escape($requiredEntry)) {
            Add-GeneratedWarning ".gitignore is missing generated-artifact ignore entry: $requiredEntry"
        }
    }
}

$statusValue = if ($issues.Count -eq 0) { "pass" } else { "fail" }
$issueLines = if ($issues.Count -eq 0) { "- none" } else { ($issues | ForEach-Object { "- $_" }) -join [Environment]::NewLine }
$warningLines = if ($warnings.Count -eq 0) { "- none" } else { ($warnings | ForEach-Object { "- $_" }) -join [Environment]::NewLine }
$stagedLines = if ($stagedGenerated.Count -eq 0) { "- none" } else { ($stagedGenerated | ForEach-Object { "- $_" }) -join [Environment]::NewLine }

$reportPath = Get-HarnessConfiguredPath -RootDir $rootDir -Name "generated_artifacts_audit" -FallbackRelativePath "harness/reports/generated_artifacts_audit.md"
$report = @"
# Generated Artifacts Audit

## Summary

- status: $statusValue
- staged_generated_count: $($stagedGenerated.Count)
- unstaged_generated_count: $($unstagedGenerated.Count)
- untracked_generated_count: $($untrackedGenerated.Count)

## Staged Generated Artifacts

$stagedLines

## Issues

$issueLines

## Warnings

$warningLines
"@
Write-Utf8File -Path $reportPath -Content $report

Write-Output "status: $statusValue"
Write-Output "report: $reportPath"
if ($issues.Count -gt 0) {
    exit 1
}
