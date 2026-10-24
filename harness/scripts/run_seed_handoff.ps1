param(
    [switch]$Ephemeral,
    [string]$Model,
    [switch]$DryRun,
    [switch]$PreflightOnly,
    [switch]$Resume,
    [int]$MaxWorkerAttempts = 3,
    [int]$StaleAfterSeconds = 7200,
    [switch]$StopOnWorkerFailure,
    [switch]$SkipAutoAdvanceGit,
    [string]$PlanFile
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")

$installHooksScript = Join-Path $PSScriptRoot "install_git_hooks.ps1"
$preflightScript = Join-Path $PSScriptRoot "run_harness_preflight.ps1"
$dispatchScript = Join-Path $PSScriptRoot "dispatch_seed_plan.ps1"

$hooksResult = Invoke-HarnessPowerShellFile -FilePath $installHooksScript -AllowFailure
if (-not [string]::IsNullOrWhiteSpace($hooksResult.Output)) {
    Write-Output $hooksResult.Output
}
if (-not $hooksResult.Success) {
    exit $hooksResult.ExitCode
}

$preflightResult = Invoke-HarnessPowerShellFile -FilePath $preflightScript -AllowFailure
if (-not [string]::IsNullOrWhiteSpace($preflightResult.Output)) {
    Write-Output $preflightResult.Output
}
if (-not $preflightResult.Success) {
    exit $preflightResult.ExitCode
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
if ($Resume) {
    $dispatchArgs += "-Resume"
}
if ($MaxWorkerAttempts -gt 0) {
    $dispatchArgs += @("-MaxWorkerAttempts", $MaxWorkerAttempts)
}
if ($StaleAfterSeconds -gt 0) {
    $dispatchArgs += @("-StaleAfterSeconds", $StaleAfterSeconds)
}
if ($StopOnWorkerFailure) {
    $dispatchArgs += "-StopOnWorkerFailure"
}
if ($SkipAutoAdvanceGit) {
    $dispatchArgs += "-SkipAutoAdvanceGit"
}
if (-not [string]::IsNullOrWhiteSpace($PlanFile)) {
    $dispatchArgs += @("-PlanFile", $PlanFile)
}

$dispatchResult = Invoke-HarnessPowerShellFile -FilePath $dispatchScript -Arguments $dispatchArgs -AllowFailure
if (-not [string]::IsNullOrWhiteSpace($dispatchResult.Output)) {
    Write-Output $dispatchResult.Output
}
$statusScript = Join-Path $PSScriptRoot "get_harness_status.ps1"
if (Test-Path -LiteralPath $statusScript) {
    Invoke-HarnessPowerShellFile -FilePath $statusScript -Arguments @("-Quiet") -AllowFailure | Out-Null
}
exit $dispatchResult.ExitCode
