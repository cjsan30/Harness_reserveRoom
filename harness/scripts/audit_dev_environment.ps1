param(
    [switch]$WarnOnly,
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
. (Join-Path $PSScriptRoot "platform_engineering_common.ps1")

$rootDir = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Get-HarnessRoot -ScriptDirectory $PSScriptRoot
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}

$issues = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$devcontainerPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath ".devcontainer/devcontainer.json" -Label "devcontainer"
$manifestPath = Resolve-HarnessEnginePath -RootDir $rootDir -ProjectPath "harness/project/configs/toolchain_manifest.json" -Label "toolchain manifest"

if (-not (Test-Path -LiteralPath $devcontainerPath)) {
    $issues.Add("missing .devcontainer/devcontainer.json") | Out-Null
} else {
    try {
        $devcontainer = Get-Content -Raw -LiteralPath $devcontainerPath | ConvertFrom-Json
        if ([string]::IsNullOrWhiteSpace([string]$devcontainer.image)) {
            $issues.Add("devcontainer image is missing") | Out-Null
        }
        if ([string]$devcontainer.postCreateCommand -notmatch "setup_portable_runtime\.sh") {
            $issues.Add("devcontainer postCreateCommand does not run setup_portable_runtime.sh") | Out-Null
        }
        $features = Get-ProjectObjectProperty -Object $devcontainer -Name "features"
        if ($null -eq $features) {
            $warnings.Add("devcontainer has no features block") | Out-Null
        }
    } catch {
        $issues.Add("devcontainer JSON is invalid: $($_.Exception.Message)") | Out-Null
    }
}

if (-not (Test-Path -LiteralPath $manifestPath)) {
    $issues.Add("missing harness/project/configs/toolchain_manifest.json") | Out-Null
} else {
    try {
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
        if ([int]$manifest.version -lt 1) {
            $issues.Add("toolchain manifest version is invalid") | Out-Null
        }
        if ([string]::IsNullOrWhiteSpace([string]$manifest.ci.required_check)) {
            $issues.Add("toolchain manifest is missing ci.required_check") | Out-Null
        }
    } catch {
        $issues.Add("toolchain manifest JSON is invalid: $($_.Exception.Message)") | Out-Null
    }
}

$misePath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath "mise.toml" -Label "mise config"
if (Test-Path -LiteralPath $misePath) {
    $miseText = Get-Content -Raw -LiteralPath $misePath
    if ($miseText -notmatch "\[tasks\.harness-preflight\]") {
        $warnings.Add("mise.toml exists but does not define tasks.harness-preflight") | Out-Null
    }
}

$status = $(if ($issues.Count -eq 0) { "pass" } else { "fail" })
$issueLines = if ($issues.Count -eq 0) { "- none" } else { ($issues.ToArray() | ForEach-Object { "- " + $_ }) -join [Environment]::NewLine }
$warningLines = if ($warnings.Count -eq 0) { "- none" } else { ($warnings.ToArray() | ForEach-Object { "- " + $_ }) -join [Environment]::NewLine }
$report = @"
# Dev Environment Audit

## Summary

- status: $status
- issues: $($issues.Count)
- warnings: $($warnings.Count)

## Issues

$issueLines

## Warnings

$warningLines
"@
$reportPath = Write-HarnessReportFile -RootDir $rootDir -FileName "dev_environment_audit.md" -Content $report

Write-Output "status: $status"
Write-Output "issues: $($issues.Count)"
Write-Output "warnings: $($warnings.Count)"
Write-Output "report: $reportPath"

if ($status -ne "pass" -and -not $WarnOnly) {
    exit 1
}
