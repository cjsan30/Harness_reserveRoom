param(
    [switch]$Force,
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
. (Join-Path $PSScriptRoot "platform_engineering_common.ps1")
. (Join-Path $PSScriptRoot "security_quality_common.ps1")

$rootDir = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Get-HarnessRoot -ScriptDirectory $PSScriptRoot
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}

$security = Get-HarnessSecurityStack -RootDir $rootDir
$paths = @(
    ".github/dependabot.yml",
    ".github/workflows/scorecard.yml",
    "harness/project/configs/security_baseline.json",
    "docs/security_baseline.md"
)
if ($security.CodeQlLanguages.Count -gt 0) {
    $paths += ".github/workflows/codeql.yml"
}

foreach ($projectPath in $paths) {
    $path = Resolve-ProjectPath -RootDir $rootDir -ProjectPath $projectPath -Label $projectPath
    if ((Test-Path -LiteralPath $path) -and -not $Force) {
        throw "file already exists: $projectPath; rerun with -Force to overwrite"
    }
}

$dependabotPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath ".github/dependabot.yml" -Label "dependabot"
$scorecardPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath ".github/workflows/scorecard.yml" -Label "scorecard workflow"
$baselinePath = Resolve-HarnessEnginePath -RootDir $rootDir -ProjectPath "harness/project/configs/security_baseline.json" -Label "security baseline"
$docPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath "docs/security_baseline.md" -Label "security baseline doc"

foreach ($path in @($dependabotPath, $scorecardPath, $baselinePath, $docPath)) {
    Ensure-HarnessDirectory -Path (Split-Path -Parent $path)
}

Write-Utf8File -Path $dependabotPath -Content (New-HarnessDependabotYaml -Updates $security.DependabotUpdates)
Write-Utf8File -Path $scorecardPath -Content (New-HarnessScorecardWorkflowYaml)

$codeqlPathText = "none"
if ($security.CodeQlLanguages.Count -gt 0) {
    $codeqlPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath ".github/workflows/codeql.yml" -Label "codeql workflow"
    Ensure-HarnessDirectory -Path (Split-Path -Parent $codeqlPath)
    Write-Utf8File -Path $codeqlPath -Content (New-HarnessCodeQlWorkflowYaml -Languages ([string[]]$security.CodeQlLanguages))
    $codeqlPathText = ".github/workflows/codeql.yml"
}

$baseline = [ordered]@{
    version = 1
    dependabot = [ordered]@{
        path = ".github/dependabot.yml"
        updates = @($security.DependabotUpdates)
    }
    codeql = [ordered]@{
        path = $codeqlPathText
        languages = @($security.CodeQlLanguages)
    }
    scorecard = [ordered]@{
        path = ".github/workflows/scorecard.yml"
        action = "ossf/scorecard-action@v2.4.3"
    }
    github_security_settings = [ordered]@{
        audit_command = "pwsh -NoProfile -File harness/scripts/audit_security_baseline.ps1 -CheckGitHubSecuritySettings"
        managed_by_files = $false
    }
}
Write-Utf8File -Path $baselinePath -Content ($baseline | ConvertTo-Json -Depth 20)

$doc = @"
# Security Baseline

## Summary

- dependabot: .github/dependabot.yml
- codeql: $codeqlPathText
- scorecard: .github/workflows/scorecard.yml
- server_security_audit: optional GitHub API check

## Rules

- Dependabot updates dependency manifests and GitHub Actions workflows.
- CodeQL scans supported languages for security and quality issues.
- OpenSSF Scorecard records repository security posture as SARIF.
- Secret scanning and push protection are GitHub repository settings; audit them with `audit_security_baseline.ps1 -CheckGitHubSecuritySettings`.
"@
Write-Utf8File -Path $docPath -Content $doc

Write-Output "dependabot: $dependabotPath"
Write-Output "codeql: $codeqlPathText"
Write-Output "scorecard: $scorecardPath"
Write-Output "security_baseline: $baselinePath"
Write-Output "security_doc: $docPath"
