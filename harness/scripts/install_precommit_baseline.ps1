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
$configPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath ".pre-commit-config.yaml" -Label "pre-commit config"
$docPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath "docs/precommit_baseline.md" -Label "pre-commit doc"

foreach ($path in @($configPath, $docPath)) {
    if ((Test-Path -LiteralPath $path) -and -not $Force) {
        throw "file already exists: $(Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $path); rerun with -Force to overwrite"
    }
}

Ensure-HarnessDirectory -Path (Split-Path -Parent $configPath)
Ensure-HarnessDirectory -Path (Split-Path -Parent $docPath)
Write-Utf8File -Path $configPath -Content (New-HarnessPreCommitYaml -LocalHooks $security.PreCommitLocalHooks)

$doc = @"
# Pre-commit Baseline

## Summary

- config: .pre-commit-config.yaml
- governance_hooks: harness Git hooks remain authoritative
- quality_hooks: pre-commit checks formatting, file size, YAML/JSON, private keys, and stack-specific quick checks

## Commands

```sh
pre-commit install
pre-commit run --all-files
```

Do not move protected-branch governance into pre-commit. The harness Git hooks still enforce branch, gate, push, and merge policy.
"@
Write-Utf8File -Path $docPath -Content $doc

Write-Output "precommit_config: $configPath"
Write-Output "precommit_doc: $docPath"
