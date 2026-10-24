$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")

$rootDir = Get-HarnessRoot -ScriptDirectory $PSScriptRoot
$latestReport = Get-HarnessConfiguredPath -RootDir $rootDir -Name "latest_report" -FallbackRelativePath "harness/reports/latest_report.md"
$outputDir = Get-HarnessConfiguredPath -RootDir $rootDir -Name "retry_prompts" -FallbackRelativePath "harness/reports/retry_prompts"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

if (-not (Test-Path -LiteralPath $latestReport)) {
    throw "latest report not found: $latestReport"
}

Ensure-HarnessDirectory -Path $outputDir
$content = Get-Content -LiteralPath $latestReport

$status = Get-MarkdownValue -Content $content -Key "status"
$sourceCycle = Get-MarkdownValue -Content $content -Key "last_cycle"
$failureType = Get-MarkdownValue -Content $content -Key "type"
$failureModule = Get-MarkdownValue -Content $content -Key "module"
$nextOwner = Get-MarkdownValue -Content $content -Key "owner"
$nextTask = Get-MarkdownValue -Content $content -Key "task"

if ([string]::IsNullOrWhiteSpace($status)) {
    throw "could not parse latest report"
}

if ($status -eq "pass" -or $status -eq "partial-pass") {
    Write-Output "latest report is pass; retry prompt not needed"
    exit 0
}

if ([string]::IsNullOrWhiteSpace($nextOwner) -or $nextOwner -eq "none") {
    $nextOwner = "manager-main"
}

if ([string]::IsNullOrWhiteSpace($failureType) -or $failureType -eq "none") {
    $failureType = Get-DispatchConfigValue -RootDir $rootDir -Name "default_failure_type" -Fallback "logic"
}

if ([string]::IsNullOrWhiteSpace($failureModule) -or $failureModule -eq "none") {
    $failureModule = "unknown"
}

if ([string]::IsNullOrWhiteSpace($nextTask) -or $nextTask -eq "none") {
    $nextTask = "inspect latest harness failure and propose a focused fix"
}

if ([string]::IsNullOrWhiteSpace($sourceCycle) -or $sourceCycle -eq "none") {
    $sourceCycle = $timestamp
}

$failureSignature = Get-FailureSignature -FailureType $failureType -FailureModule $failureModule -Task $nextTask
$attemptInfo = Get-RetryAttemptInfo -RetryDir $outputDir -FailureSignature $failureSignature -SourceCycle $sourceCycle

if (-not [string]::IsNullOrWhiteSpace($attemptInfo.ExistingPrompt)) {
    Write-Output "retry prompt already exists for this cycle: $($attemptInfo.ExistingPrompt)"
    exit 0
}

$defaultValidation = Get-ProjectCommand -RootDir $rootDir -Name "integration" -Fallback "make integration"
$validation = Get-OwnerValidationCommand -RootDir $rootDir -Owner $nextOwner -Fallback $defaultValidation
if ([string]::IsNullOrWhiteSpace($validation)) {
    $validation = "make test"
}

$promptId = "${timestamp}_${nextOwner}"
$outputFile = Join-Path $outputDir ($promptId + ".md")

$body = @"
# Retry Prompt

## Meta

- prompt_id: $promptId
- attempt: $($attemptInfo.NextAttempt)
- source_cycle: $sourceCycle
- failure_signature: $failureSignature

## Owner

- agent: $nextOwner

## Failure Type

- type: $failureType

## Affected Area

- files: inspect harness/reports/latest_report.md and related logs
- module: $failureModule

## What Failed

- summary: The latest harness cycle did not pass and has been assigned to $nextOwner.

## Required Fix

- task: $nextTask

## Validation Needed

- command: $validation
- expected: the assigned failure is resolved and the next harness cycle moves forward
"@

Write-Utf8File -Path $outputFile -Content $body
Write-Output "generated retry prompt: $outputFile"
