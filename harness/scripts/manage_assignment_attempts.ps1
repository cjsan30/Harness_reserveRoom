param(
    [Parameter(Mandatory = $true)][string]$AssignmentId,
    # Extra attempts for this assignment only; requires -Reason. Omit to show the status.
    [int]$Grant = 0,
    [string]$Reason,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$root = Get-HarnessRoot $PSScriptRoot
$null = Assert-SafePathToken $AssignmentId 'assignment id'

if ($Grant -ne 0) {
    $before = Get-HarnessAssignmentAttemptStatus $root $AssignmentId
    # A grant for an assignment that never ran is most likely a typo.
    if ($before.invocations -eq 0) { throw "no recorded invocation for assignment: $AssignmentId" }
    $null = Add-HarnessAttemptGrant $root $AssignmentId $Grant $Reason 'cli'
}

$status = Get-HarnessAssignmentAttemptStatus $root $AssignmentId
$history = Read-HarnessFailureHistory $root $AssignmentId
$report = [pscustomobject]@{
    status = $status
    grants = @(Read-HarnessAttemptGrants $root $AssignmentId)
    attempts = @($history.attempts | ForEach-Object { [pscustomobject]@{ invocation_id = $_.invocation_id; classified_at = $_.classified_at; class = $_.class; kind = $_.kind; counts = $_.counts_toward_assignment_limit; signature = $_.signature; summary = $_.summary } })
}
if ($Json) { $report | ConvertTo-Json -Depth 8; exit 0 }
$limitText = if ($null -eq $status.limit) { 'no limit' } else { "$($status.counted) of $($status.limit) counted (policy $($status.policy_limit) + granted $($status.granted_extra))" }
Write-Output "assignment: $AssignmentId"
Write-Output "invocations: $($status.invocations) (not counted: $($status.not_counted))"
Write-Output "attempt limit: $limitText"
foreach ($attempt in $report.attempts) {
    Write-Output ("- {0} {1}/{2} counts={3}: {4}" -f $attempt.classified_at, $attempt.class, $attempt.kind, ([string]$attempt.counts).ToLowerInvariant(), $attempt.summary)
}
if ($Grant -ne 0) { Write-Output "granted $Grant extra attempt(s); continue with resume" }
