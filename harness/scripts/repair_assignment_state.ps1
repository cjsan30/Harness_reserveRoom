param(
    [Parameter(Mandatory=$true)][string]$Agent,
    [string]$AssignmentId,
    # Operator decision: turn a pass record that cannot be bound to execution evidence
    # into a failure so the assignment can be retried. Requires -Reason.
    [switch]$MarkFailed,
    [string]$Reason
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$root = Get-HarnessRoot $PSScriptRoot
$lease = Enter-AssignmentQueue $root $Agent
Release-HarnessLock $lease
if ($MarkFailed -and -not $AssignmentId) { throw '-MarkFailed requires -AssignmentId' }
if ($AssignmentId) {
    Repair-AssignmentWorkerExit $root $Agent $AssignmentId -MarkFailed:$MarkFailed -Reason $Reason
    if ($MarkFailed) { Write-Output "pass record marked failed after operator review: $AssignmentId (retry with resume)" }
    Write-Output "queue and confirmed worker exit reconciled: $AssignmentId"
} else {
    Write-Output "queue journals reconciled: $Agent"
}
