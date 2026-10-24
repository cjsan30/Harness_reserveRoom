param(
    [string]$RepositoryRoot,
    [switch]$CheckGitHubApi,
    [switch]$RequireGitRemote,
    [switch]$RequireGitHubCli,
    [switch]$RequireGitHubApi
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
. (Join-Path $PSScriptRoot "github_pr_common.ps1")

$rootDir = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Get-HarnessRoot -ScriptDirectory $PSScriptRoot
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}

$issues = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-AuthIssue {
    param([string]$Message)
    $issues.Add($Message) | Out-Null
}

function Add-AuthWarning {
    param([string]$Message)
    $warnings.Add($Message) | Out-Null
}

$originUrl = ""
$gitRemoteStatus = "skip"
$gitRemoteDetail = "origin remote is not configured"
$originResult = Invoke-HarnessProcess -Executable "git" -Arguments @("remote", "get-url", "origin") -WorkingDirectory $rootDir -AllowFailure
if ($originResult.Success -and -not [string]::IsNullOrWhiteSpace($originResult.Output)) {
    $originUrl = $originResult.Output.Trim()
    $lsRemote = Invoke-HarnessProcess -Executable "git" -Arguments @("ls-remote", "--heads", "origin") -WorkingDirectory $rootDir -AllowFailure
    if ($lsRemote.Success) {
        $gitRemoteStatus = "pass"
        $gitRemoteDetail = "git fetch/push credential path can reach origin heads"
    } else {
        $gitRemoteStatus = "fail"
        $gitRemoteDetail = $lsRemote.Output
        if ($RequireGitRemote) {
            Add-AuthIssue "git origin is configured but not reachable through git ls-remote"
        } else {
            Add-AuthWarning "git origin is configured but not reachable through git ls-remote"
        }
    }
} elseif ($RequireGitRemote) {
    Add-AuthIssue "origin remote is required but not configured"
} else {
    Add-AuthWarning "origin remote is not configured; git remote auth audit skipped"
}

$ghStatus = "skip"
$ghDetail = "gh was not checked"
$ghApiStatus = "skip"
$ghApiDetail = "GitHub API check was not requested"
try {
    $ghPath = Get-GitHubCliExecutable -RootDir $rootDir
    $ghAuth = Invoke-GitHubCli -RootDir $rootDir -Arguments @("auth", "status", "--active") -AllowFailure
    if ($ghAuth.Success) {
        $ghStatus = "pass"
        $ghDetail = "gh authenticated: $ghPath"
    } else {
        $ghStatus = "fail"
        $ghDetail = $ghAuth.Output
        if ($RequireGitHubCli) {
            Add-AuthIssue "gh CLI authentication is required but failed"
        } else {
            Add-AuthWarning "gh CLI authentication failed; PR/ruleset automation is unavailable"
        }
    }

    if ($CheckGitHubApi -or $RequireGitHubApi) {
        $apiResult = Invoke-GitHubCli -RootDir $rootDir -Arguments @("api", "user") -AllowFailure
        if ($apiResult.Success) {
            $ghApiStatus = "pass"
            $ghApiDetail = "gh api user succeeded"
        } else {
            $ghApiStatus = "fail"
            $ghApiDetail = $apiResult.Output
            if ($RequireGitHubApi) {
                Add-AuthIssue "GitHub API access is required but gh api user failed"
            } else {
                Add-AuthWarning "GitHub API access check failed; ruleset/security audits may fail"
            }
        }
    }
} catch {
    $ghStatus = "fail"
    $ghDetail = $_.Exception.Message
    if ($RequireGitHubCli) {
        Add-AuthIssue $_.Exception.Message
    } else {
        Add-AuthWarning $_.Exception.Message
    }
}

$statusValue = if ($issues.Count -eq 0) { "pass" } else { "fail" }
$issueLines = if ($issues.Count -eq 0) { "- none" } else { ($issues | ForEach-Object { "- $_" }) -join [Environment]::NewLine }
$warningLines = if ($warnings.Count -eq 0) { "- none" } else { ($warnings | ForEach-Object { "- $_" }) -join [Environment]::NewLine }
$reportPath = Get-HarnessConfiguredPath -RootDir $rootDir -Name "git_remote_auth_audit" -FallbackRelativePath "harness/reports/git_remote_auth_audit.md"
$report = @"
# Git Remote Auth Audit

## Summary

- status: $statusValue
- origin_url: $(if ([string]::IsNullOrWhiteSpace($originUrl)) { "none" } else { $originUrl })
- git_remote_status: $gitRemoteStatus
- gh_cli_status: $ghStatus
- github_api_status: $ghApiStatus

## Details

- git_remote_detail: $($gitRemoteDetail -replace "\r?\n", " ")
- gh_cli_detail: $($ghDetail -replace "\r?\n", " ")
- github_api_detail: $($ghApiDetail -replace "\r?\n", " ")

## Issues

$issueLines

## Warnings

$warningLines
"@
Write-Utf8File -Path $reportPath -Content $report

Write-Output "status: $statusValue"
Write-Output "git_remote_status: $gitRemoteStatus"
Write-Output "gh_cli_status: $ghStatus"
Write-Output "github_api_status: $ghApiStatus"
Write-Output "report: $reportPath"
if ($issues.Count -gt 0) {
    exit 1
}
