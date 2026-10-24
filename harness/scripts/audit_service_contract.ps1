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
$contractPath = Resolve-HarnessEnginePath -RootDir $rootDir -ProjectPath "harness/project/configs/service_contract.json" -Label "service contract"
$composePath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath "docker-compose.harness.yml" -Label "service compose"

if (-not (Test-Path -LiteralPath $contractPath)) {
    $issues.Add("missing harness/project/configs/service_contract.json") | Out-Null
} else {
    try {
        $contract = Get-Content -Raw -LiteralPath $contractPath | ConvertFrom-Json
        $ids = New-Object System.Collections.Generic.HashSet[string]
        foreach ($service in @($contract.services)) {
            $id = [string]$service.id
            if ([string]::IsNullOrWhiteSpace($id)) {
                $issues.Add("service id is missing") | Out-Null
            } elseif (-not $ids.Add($id)) {
                $issues.Add("duplicate service id: $id") | Out-Null
            }
            if ([string]::IsNullOrWhiteSpace([string]$service.image)) {
                $issues.Add("service '$id' image is missing") | Out-Null
            }
            foreach ($property in @($service.env.PSObject.Properties)) {
                $value = [string]$property.Value
                if ($property.Name -match "TOKEN|SECRET|API_KEY" -or $value -match "ghp_|sk-|xoxb-") {
                    $issues.Add("service '$id' appears to contain a real secret-like value in $($property.Name)") | Out-Null
                }
            }
        }
        if (@($contract.services).Count -gt 0) {
            if (-not (Test-Path -LiteralPath $composePath)) {
                $issues.Add("service contract declares services but docker-compose.harness.yml is missing") | Out-Null
            } else {
                $composeText = Get-Content -Raw -LiteralPath $composePath
                foreach ($service in @($contract.services)) {
                    if ($composeText -notmatch ("(?m)^\s{2}" + [System.Text.RegularExpressions.Regex]::Escape([string]$service.id) + ":")) {
                        $issues.Add("compose file does not define service '$($service.id)'") | Out-Null
                    }
                }
                foreach ($unexpected in @("Count:", "Keys:", "Values:", "SyncRoot:", "IsReadOnly:", "IsFixedSize:", "IsSynchronized:")) {
                    if ($composeText -match [System.Text.RegularExpressions.Regex]::Escape($unexpected)) {
                        $issues.Add("compose file contains serialized dictionary internals: $unexpected") | Out-Null
                    }
                }
            }
        } else {
            $warnings.Add("service contract declares no external services") | Out-Null
        }
    } catch {
        $issues.Add("service contract JSON is invalid: $($_.Exception.Message)") | Out-Null
    }
}

$status = $(if ($issues.Count -eq 0) { "pass" } else { "fail" })
$issueLines = if ($issues.Count -eq 0) { "- none" } else { ($issues.ToArray() | ForEach-Object { "- " + $_ }) -join [Environment]::NewLine }
$warningLines = if ($warnings.Count -eq 0) { "- none" } else { ($warnings.ToArray() | ForEach-Object { "- " + $_ }) -join [Environment]::NewLine }
$report = @"
# Service Contract Audit

## Summary

- status: $status
- issues: $($issues.Count)
- warnings: $($warnings.Count)

## Issues

$issueLines

## Warnings

$warningLines
"@
$reportPath = Write-HarnessReportFile -RootDir $rootDir -FileName "service_contract_audit.md" -Content $report

Write-Output "status: $status"
Write-Output "issues: $($issues.Count)"
Write-Output "warnings: $($warnings.Count)"
Write-Output "report: $reportPath"

if ($status -ne "pass" -and -not $WarnOnly) {
    exit 1
}
