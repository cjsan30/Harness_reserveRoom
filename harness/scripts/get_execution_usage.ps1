param([switch]$Json)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$root=Get-HarnessRoot $PSScriptRoot
$lease=Acquire-HarnessLock (Get-HarnessLockRoot $root) 'execution_budget'
if ($null -eq $lease) { throw 'execution accounting is busy; retry report' }
try {
    $records=@(Read-HarnessUsageRecords $root)
    $report=[pscustomobject]@{ scope='all retained Harness invocations in this project'; policy=(Get-HarnessExecutionPolicy $root); totals=(Get-HarnessUsageTotals $records); invocations=$records }
} finally { Release-HarnessLock $lease }
if ($Json) { $report | ConvertTo-Json -Depth 10 }
else {
    $report.totals | Format-List | Out-String | Write-Output
    Write-Output 'Token/time thresholds stop subsequent launches; they do not interrupt a running worker. Unknown usage is not zero. No subscription quota or billing amount is inferred.'
}
