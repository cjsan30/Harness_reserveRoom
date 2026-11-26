param(
    # Run the repairs the profile declares for failing requirements.
    [switch]$Repair,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$root = Get-HarnessRoot $PSScriptRoot
$report = Get-HarnessEnvironmentReadiness $root -Repair:$Repair
if ($Json) { $report | ConvertTo-Json -Depth 6; exit 0 }
Write-Output "environment: $($report.status)"
if ($report.status -eq 'undeclared') {
    Write-Output 'The profile declares no environment requirements. Decide them during planning, before a paid run:'
    Write-Output '  add an "environment" section with requirements (id, check) and, where wanted, repairs (start/run, check, wait_seconds).'
}
foreach ($item in $report.requirements) {
    Write-Output ("- {0} [{1}]: {2} ({3})" -f $item.id, $item.source, $item.state, $item.message)
    if ($item.state -eq 'missing') { Write-Output "  install it yourself, then run this check again; the harness never installs a missing tool" }
    if ($item.state -eq 'needs_decision') { Write-Output "  decide how to provide $($item.id): fix it yourself, or declare a repair for it" }
}
foreach ($id in $report.undeclared_repairs) {
    Write-Output "- known errors refer to repair '$id', which the profile does not declare; such failures will stop the run instead of being repaired"
}
