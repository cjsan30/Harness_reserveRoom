param(
    [Parameter(Mandatory=$true)][string]$Agent,
    [string]$AssignmentId
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$root = Get-HarnessRoot $PSScriptRoot
$lease = Enter-AssignmentQueue $root $Agent
Release-HarnessLock $lease
if ($AssignmentId) {
    Repair-AssignmentWorkerExit $root $Agent $AssignmentId
    Write-Output "queue and confirmed worker exit reconciled: $AssignmentId"
} else {
    Write-Output "queue journals reconciled: $Agent"
}
