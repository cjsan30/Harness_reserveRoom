param(
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")

$rootDir = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Get-HarnessRoot -ScriptDirectory $PSScriptRoot
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}

$issues = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-LayoutIssue {
    param([string]$Message)
    $issues.Add($Message) | Out-Null
}

function Add-LayoutWarning {
    param([string]$Message)
    $warnings.Add($Message) | Out-Null
}

$standaloneHarness = (
    (Test-Path -LiteralPath (Join-Path $rootDir (ConvertTo-HarnessNativeRelativePath -Path "scripts/harness_common.ps1"))) -and
    (Test-Path -LiteralPath (Join-Path $rootDir (ConvertTo-HarnessNativeRelativePath -Path "project/configs/project_profile.json"))) -and
    (Test-Path -LiteralPath (Join-Path $rootDir (ConvertTo-HarnessNativeRelativePath -Path "githooks/pre-commit")))
)

$requiredPaths = if ($standaloneHarness) {
    @(
        "scripts/harness_common.ps1",
        "scripts/run_harness_preflight.ps1",
        "scripts/path_common.sh",
        "scripts/powershell_env.sh",
        "configs/project_profile.template.json",
        "githooks/pre-commit",
        "githooks/pre-push",
        "project/configs/project_profile.json"
    )
} else {
    $harnessRoot = Join-Path $rootDir "harness"
    if (-not (Test-Path -LiteralPath $harnessRoot -PathType Container)) {
        Add-LayoutIssue "missing harness/ directory at repository root"
    }
    @(
        "harness/scripts/harness_common.ps1",
        "harness/scripts/run_harness_preflight.ps1",
        "harness/scripts/path_common.sh",
        "harness/scripts/powershell_env.sh",
        "harness/configs/project_profile.template.json",
        "harness/githooks/pre-commit",
        "harness/githooks/pre-push",
        "harness/project/configs/project_profile.json"
    )
}

foreach ($relativePath in $requiredPaths) {
    $path = Join-Path $rootDir (ConvertTo-HarnessNativeRelativePath -Path $relativePath)
    if (-not (Test-Path -LiteralPath $path)) {
        Add-LayoutIssue "missing expected ported harness path: $relativePath"
    }
}

if (-not $standaloneHarness) {
    foreach ($misplaced in @(
            "scripts/harness_common.ps1",
            "scripts/run_harness_preflight.ps1",
            "configs/project_profile.template.json",
            "githooks/pre-commit",
            "project/configs/project_profile.json"
        )) {
        $path = Join-Path $rootDir (ConvertTo-HarnessNativeRelativePath -Path $misplaced)
        if (Test-Path -LiteralPath $path) {
            Add-LayoutWarning "possible un-nested harness file at repository root: $misplaced"
        }
    }
} else {
    Add-LayoutWarning "standalone harness layout detected; nested target-root/harness layout audit was skipped"
}

$profileRelativePath = if ($standaloneHarness) { "project/configs/project_profile.json" } else { "harness/project/configs/project_profile.json" }
$profilePath = Join-Path $rootDir (ConvertTo-HarnessNativeRelativePath -Path $profileRelativePath)
if (Test-Path -LiteralPath $profilePath) {
    try {
        $profile = Get-Content -Raw -LiteralPath $profilePath | ConvertFrom-Json
        $repoRoot = Get-ProjectObjectProperty -Object (Get-ProjectObjectProperty -Object $profile -Name "project") -Name "repository_root"
        if (-not [string]::IsNullOrWhiteSpace($repoRoot) -and $repoRoot -ne ".") {
            Add-LayoutWarning "project.repository_root is '$repoRoot'; most ported repositories should use '.'"
        }
    } catch {
        Add-LayoutIssue "failed to parse harness/project/configs/project_profile.json: $($_.Exception.Message)"
    }
}

$statusValue = if ($issues.Count -eq 0) { "pass" } else { "fail" }
$issueLines = if ($issues.Count -eq 0) { "- none" } else { ($issues | ForEach-Object { "- $_" }) -join [Environment]::NewLine }
$warningLines = if ($warnings.Count -eq 0) { "- none" } else { ($warnings | ForEach-Object { "- $_" }) -join [Environment]::NewLine }
$reportPath = Get-HarnessConfiguredPath -RootDir $rootDir -Name "porting_layout_audit" -FallbackRelativePath "harness/reports/porting_layout_audit.md"
$report = @"
# Porting Layout Audit

## Summary

- status: $statusValue
- repository_root: $rootDir

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
