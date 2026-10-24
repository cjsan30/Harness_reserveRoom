param(
    [string]$IntakeFile = "docs/project_intake.md"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
. (Join-Path $PSScriptRoot "intake_safety.ps1")

$rootDir = Get-HarnessRoot -ScriptDirectory $PSScriptRoot
$intakePath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath $IntakeFile -Label "project intake file"
$envManifestPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath "docs/env_manifest.md" -Label "env manifest"
$envExamplePath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath ".env.example" -Label "env example"
$sensitiveReportPath = Resolve-HarnessEnginePath -RootDir $rootDir -ProjectPath "harness/reports/sensitive_followups.md" -Label "sensitive followups"

function Get-IntakeSectionText {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines,
        [Parameter(Mandatory = $true)]
        [string]$SectionName,
        [int]$Level = 2
    )

    $header = ("#" * $Level) + " " + $SectionName
    $startIndex = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -eq $header) {
            $startIndex = $i + 1
            break
        }
    }

    if ($startIndex -lt 0 -or $startIndex -ge $Lines.Count) {
        return ""
    }

    $endIndex = $Lines.Count
    for ($i = $startIndex; $i -lt $Lines.Count; $i++) {
        $trimmed = $Lines[$i].Trim()
        if ($trimmed -match "^#{1,$Level} ") {
            $endIndex = $i
            break
        }
    }

    if ($endIndex -le $startIndex) {
        return ""
    }

    return (@($Lines[$startIndex..($endIndex - 1)]) -join [Environment]::NewLine).Trim()
}

function Test-SectionEmpty {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $true
    }

    $normalized = (($Value -replace "^[\s>*-]+", "").Trim())
    return ($normalized -eq "none" -or $normalized -eq "no known constraints")
}

function Get-EnvVarNames {
    param([string]$Text)

    $names = New-Object System.Collections.Generic.HashSet[string]
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $matches = [Regex]::Matches($Text, "\b[A-Z][A-Z0-9_]{2,}\b")
    foreach ($match in $matches) {
        $name = $match.Value
        if ($name -in @("API", "URL", "URI", "JSON", "JWT", "CLI", "HTTP", "HTTPS", "OAuth".ToUpperInvariant())) {
            continue
        }
        if ($name.Contains("_") -or $name -match "(KEY|TOKEN|SECRET|PASSWORD|PASS|URL|URI|DSN|HOST|PORT|USER|CLIENT_ID|CLIENT_SECRET|DATABASE)$") {
            $names.Add($name) | Out-Null
        }
    }

    return @($names | Sort-Object)
}

if (-not (Test-Path -LiteralPath $intakePath)) {
    throw "intake file not found: $IntakeFile"
}

$lines = @(ConvertTo-SafeHarnessIntake -Lines @(Get-Content -Encoding UTF8 -LiteralPath $intakePath))
Assert-HarnessIntakeHasNoCredentials -Lines $lines
$preparedData = Get-IntakeSectionText -Lines $lines -SectionName "Prepared Data"
$externalDependencies = Get-IntakeSectionText -Lines $lines -SectionName "External Dependencies"
$secretsAndAccess = Get-IntakeSectionText -Lines $lines -SectionName "Secrets And Access"
$requirements = Get-IntakeSectionText -Lines $lines -SectionName "Requirements"
$combined = @($preparedData, $externalDependencies, $secretsAndAccess, $requirements) -join [Environment]::NewLine
$envNames = @(Get-EnvVarNames -Text $combined)

$envRows = New-Object System.Collections.Generic.List[string]
if ($envNames.Count -eq 0) {
    $envRows.Add("| none | not specified | no | none |") | Out-Null
} else {
    foreach ($name in $envNames) {
        $requiredLater = if ($name -match "(SECRET|TOKEN|KEY|PASSWORD|CLIENT_SECRET)") { "yes" } else { "project-dependent" }
        $envRows.Add("| $name | fill later through local environment; do not commit a real value | $requiredLater | leave empty in .env.example |") | Out-Null
    }
}

$preparedText = if (Test-SectionEmpty -Value $preparedData) { "- none" } else { $preparedData }
$externalText = if (Test-SectionEmpty -Value $externalDependencies) { "- none" } else { $externalDependencies }
$secretsText = if (Test-SectionEmpty -Value $secretsAndAccess) { "- none" } else { $secretsAndAccess }

$manifest = @"
# Environment Manifest

## Policy

- Do not commit real private tokens, passwords, API keys, or personal credentials.
- This file records required names, safe fixture data, and local/mock setup only.
- Put real values in the developer's local environment or an ignored .env file.

## Environment Variables

| name | purpose | required_later | .env.example value |
| --- | --- | --- | --- |
$($envRows -join [Environment]::NewLine)

## Prepared Data

$preparedText

## External Dependencies

$externalText

## Secrets And Access

$secretsText
"@
Write-Utf8File -Path $envManifestPath -Content $manifest

$exampleLines = New-Object System.Collections.Generic.List[string]
$exampleLines.Add("# Example environment file generated by the harness.") | Out-Null
$exampleLines.Add("# Do not put real secrets in version control.") | Out-Null
if ($envNames.Count -eq 0) {
    $exampleLines.Add("# No explicit environment variable names were found in project intake.") | Out-Null
} else {
    foreach ($name in $envNames) {
        $exampleLines.Add("$name=") | Out-Null
    }
}
Write-Utf8File -Path $envExamplePath -Content ($exampleLines -join [Environment]::NewLine)

$sensitiveFollowups = @"
# Sensitive Follow-Ups

## Summary

- source: $IntakeFile
- env_manifest: $(Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $envManifestPath)
- env_example: $(Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $envExamplePath)
- explicit_env_var_count: $($envNames.Count)
- recorded_at: $((Get-Date).ToString("o"))

## Required Later

$secretsText

## Environment Variable Names

$(if ($envNames.Count -eq 0) { "- none specified" } else { ($envNames | ForEach-Object { "- $_" }) -join [Environment]::NewLine })

## Rule

- Keep real values outside Git. Use local environment variables, ignored .env, or the deployment platform's secret store.
"@
Write-Utf8File -Path $sensitiveReportPath -Content $sensitiveFollowups

Write-Output "env manifest: $envManifestPath"
Write-Output "env example: $envExamplePath"
Write-Output "sensitive followups: $sensitiveReportPath"
