$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")

$rootDir = Get-HarnessRoot -ScriptDirectory $PSScriptRoot
$profilePath = Get-ProjectProfilePath -RootDir $rootDir
if ([string]::IsNullOrWhiteSpace($profilePath)) {
    throw "project profile not found"
}

$profile = Get-ProjectProfile -RootDir $rootDir
$outputPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath "docs/project_profile_generated.md" -Label "generated profile doc"
$project = Get-ProjectObjectProperty -Object $profile -Name "project"
$requirements = Get-ProjectObjectProperty -Object $profile -Name "requirements"
$commands = Get-ProjectObjectProperty -Object $profile -Name "commands"
$owners = Get-ProjectObjectProperty -Object $profile -Name "owners"
$dispatch = Get-ProjectObjectProperty -Object $profile -Name "dispatch"
$harnessConfig = Get-ProjectObjectProperty -Object $profile -Name "harness"
$failurePatterns = Get-ProjectObjectProperty -Object $profile -Name "failure_patterns"
$gitWorkflow = Get-ProjectObjectProperty -Object $profile -Name "git_workflow"

$projectName = Get-ProjectObjectProperty -Object $project -Name "name"
$summary = Get-ProjectObjectProperty -Object $project -Name "summary"
$language = Get-ProjectObjectProperty -Object $project -Name "language"
$runtime = Get-ProjectObjectProperty -Object $project -Name "runtime"
$framework = Get-ProjectObjectProperty -Object $project -Name "framework"
$ide = Get-ProjectObjectProperty -Object $project -Name "ide"

$sourceDocs = Get-ProfileStringArray -Value (Get-ProjectObjectProperty -Object $requirements -Name "source_docs")
$successCriteria = Get-ProfileStringArray -Value (Get-ProjectObjectProperty -Object $requirements -Name "success_criteria")
$relativeProfilePath = Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $profilePath

$commandLines = @()
foreach ($property in $commands.PSObject.Properties) {
    $commandLines += "- $($property.Name): $($property.Value)"
}
$commandBlock = $commandLines -join [Environment]::NewLine

$ownerSections = New-Object System.Collections.Generic.List[string]
foreach ($ownerProperty in $owners.PSObject.Properties) {
    $ownerName = $ownerProperty.Name
    $ownerConfig = $ownerProperty.Value
    $readList = Get-ProfileStringArray -Value (Get-ProjectObjectProperty -Object $ownerConfig -Name "read")
    $failureScope = Get-ProfileStringArray -Value (Get-ProjectObjectProperty -Object $ownerConfig -Name "failure_scope")
    $workArea = Get-ProjectObjectProperty -Object $ownerConfig -Name "work_area"
    $validation = Get-ProjectObjectProperty -Object $ownerConfig -Name "validation"
    $readText = (($readList | ForEach-Object { "- $_" }) -join [Environment]::NewLine)
    $scopeText = (($failureScope | ForEach-Object { "- $_" }) -join [Environment]::NewLine)
    $section = @"
### $ownerName

- work_area: $workArea
- validation: $validation

Read first:

$readText

Failure scope:

$scopeText
"@
    $ownerSections.Add($section) | Out-Null
}

$dispatchLines = @()
foreach ($property in $dispatch.PSObject.Properties) {
    $dispatchLines += "- $($property.Name): $($property.Value)"
}
$dispatchBlock = $dispatchLines -join [Environment]::NewLine

$harnessLines = @()
foreach ($property in $harnessConfig.PSObject.Properties) {
    $harnessLines += "- $($property.Name): $($property.Value)"
}
$harnessBlock = $harnessLines -join [Environment]::NewLine

$gitWorkflowLines = @()
if ($null -ne $gitWorkflow) {
    foreach ($property in $gitWorkflow.PSObject.Properties) {
        $gitWorkflowLines += "- $($property.Name): $($property.Value)"
    }
}
if ($gitWorkflowLines.Count -eq 0) {
    $gitWorkflowLines += "- none"
}
$gitWorkflowBlock = $gitWorkflowLines -join [Environment]::NewLine

$patternSections = @()
foreach ($property in $failurePatterns.PSObject.Properties) {
    $values = Get-ProfileStringArray -Value $property.Value
    $valueText = (($values | ForEach-Object { "- $_" }) -join [Environment]::NewLine)
    $patternSections += @"
### $($property.Name)

$valueText
"@
}
$patternBlock = $patternSections -join [Environment]::NewLine + [Environment]::NewLine

$doc = @"
# Project Profile Summary

Generated from:

- $relativeProfilePath

## Project

- name: $projectName
- language: $language
- runtime: $runtime
- framework: $framework
- ide: $ide

## Summary

$summary

## Source Docs

$(($sourceDocs | ForEach-Object { "- $_" }) -join [Environment]::NewLine)

## Success Criteria

$(($successCriteria | ForEach-Object { "- $_" }) -join [Environment]::NewLine)

## Commands

$commandBlock

## Owners

$($ownerSections -join [Environment]::NewLine)

## Dispatch

$dispatchBlock

## Failure Patterns

$patternBlock
## Git Workflow

$gitWorkflowBlock

## Harness Paths

$harnessBlock
"@

Write-Utf8File -Path $outputPath -Content $doc
Write-Output "generated profile docs: $outputPath"
