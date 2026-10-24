param(
    [switch]$Ephemeral,
    [string]$Model,
    [switch]$DryRun,
    [switch]$PreflightOnly,
    [string]$PromptId
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")

$preflightScript = Join-Path $PSScriptRoot "run_harness_preflight.ps1"
$generateScript = Join-Path $PSScriptRoot "generate_retry_prompt.ps1"
$dispatchScript = Join-Path $PSScriptRoot "dispatch_retry_prompt.ps1"

$preflightResult = Invoke-HarnessPowerShellFile -FilePath $preflightScript -AllowFailure
if (-not [string]::IsNullOrWhiteSpace($preflightResult.Output)) {
    Write-Output $preflightResult.Output
}
if (-not $preflightResult.Success) {
    exit $preflightResult.ExitCode
}

$generateResult = Invoke-HarnessPowerShellFile -FilePath $generateScript -AllowFailure
if (-not [string]::IsNullOrWhiteSpace($generateResult.Output)) {
    Write-Output $generateResult.Output
}
if (-not $generateResult.Success) {
    exit $generateResult.ExitCode
}

$dispatchArgs = @(
    "-InvokeCodex"
)
if ($Ephemeral) {
    $dispatchArgs += "-Ephemeral"
}
if (-not [string]::IsNullOrWhiteSpace($Model)) {
    $dispatchArgs += @("-Model", $Model)
}
if ($DryRun) {
    $dispatchArgs += "-DryRun"
}
if ($PreflightOnly) {
    $dispatchArgs += "-PreflightOnly"
}
if (-not [string]::IsNullOrWhiteSpace($PromptId)) {
    $dispatchArgs += @("-PromptId", $PromptId)
}

$dispatchResult = Invoke-HarnessPowerShellFile -FilePath $dispatchScript -Arguments $dispatchArgs -AllowFailure
if (-not [string]::IsNullOrWhiteSpace($dispatchResult.Output)) {
    Write-Output $dispatchResult.Output
}
exit $dispatchResult.ExitCode
