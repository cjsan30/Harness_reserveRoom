param(
    [Parameter(Mandatory = $true)]
    [string]$Agent,
    [switch]$Ephemeral,
    [string]$Model,
    [switch]$DryRun,
    [switch]$PreflightOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")

$rootDir = Get-HarnessRoot -ScriptDirectory $PSScriptRoot
$ownerDirs = Get-AssignmentDirectories -RootDir $rootDir -Owner $Agent
$invokeScript = Join-Path $PSScriptRoot "invoke_assignment_codex.ps1"
$staleAfterSeconds = Get-HarnessConfiguredInteger -RootDir $rootDir -Name "assignment_stale_seconds" -Fallback 7200
$recoveredAssignments = Restore-StaleInProgressAssignments -RootDir $rootDir -Owner $Agent -StaleAfterSeconds $staleAfterSeconds
foreach ($recoveredAssignment in $recoveredAssignments) {
    Write-Output "recovered stale assignment: $recoveredAssignment"
}

$pendingFile = Get-ChildItem -LiteralPath $ownerDirs.Inbox -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime |
    Select-Object -First 1

if ($null -eq $pendingFile) {
    $pendingFile = Get-ChildItem -LiteralPath $ownerDirs.InProgress -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime |
        Select-Object -First 1
}

if ($null -eq $pendingFile) {
    Write-Output "no pending assignment found for owner: $Agent"
    exit 0
}

$content = Get-Content -LiteralPath $pendingFile.FullName
$assignmentId = Get-MarkdownValue -Content $content -Key "assignment_id"
if ([string]::IsNullOrWhiteSpace($assignmentId)) {
    $assignmentId = $pendingFile.BaseName
}

$invokeArgs = @(
    "-Agent", $Agent,
    "-AssignmentId", $assignmentId
)
if ($Ephemeral) {
    $invokeArgs += "-Ephemeral"
}
if (-not [string]::IsNullOrWhiteSpace($Model)) {
    $invokeArgs += @("-Model", $Model)
}
if ($DryRun) {
    $invokeArgs += "-DryRun"
}
if ($PreflightOnly) {
    $invokeArgs += "-PreflightOnly"
}

Write-Output "selected pending assignment: $assignmentId"
Write-Output "assignment_file: $($pendingFile.FullName)"

$invokeResult = Invoke-HarnessPowerShellFile -FilePath $invokeScript -Arguments $invokeArgs -AllowFailure
if (-not [string]::IsNullOrWhiteSpace($invokeResult.Output)) {
    Write-Output $invokeResult.Output
}
exit $invokeResult.ExitCode
