param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$engine=Split-Path -Parent $PSScriptRoot
if(-not $OutputDirectory){$OutputDirectory=Join-Path $engine '.test-output'}
$testRoot=Join-Path $OutputDirectory ([Guid]::NewGuid().ToString('N'))
Ensure-HarnessDirectory $testRoot
$results=New-Object 'System.Collections.Generic.List[object]'
function Assert-True($Value,[string]$Message){if(-not $Value){throw $Message}}
function Assert-Rejected([scriptblock]$Body){$rejected=$false;try{& $Body | Out-Null}catch{$rejected=$true};Assert-True $rejected 'operation should have been rejected'}
function Test-Case([string]$Name,[scriptblock]$Body){try{& $Body;$results.Add(@{name=$Name;passed=$true});Write-Output "PASS $Name"}catch{$results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message});Write-Output "FAIL $Name : $($_.Exception.Message)"}}
function New-Fixture($Policy=@{}){
    $root=Join-Path $testRoot ([Guid]::NewGuid().ToString('N'))
    $profile=[pscustomobject]@{execution_policy=[pscustomobject]$Policy}
    Write-Utf8File (Join-Path $root 'harness/project/configs/project_profile.json') ($profile|ConvertTo-Json -Depth 8)
    return $root
}
function New-Record([string]$Id='task'){
    return [pscustomobject]@{invocation_id=[Guid]::NewGuid().ToString('N');assignment_id=$Id;owner='tester';arguments=@('exec','--json','-m','fixture-model')}
}
function Write-UsageLog([string]$Root,[string]$Body='{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20}}'){
    $path=Join-Path $Root 'events.log'
    Write-Utf8File $path ('{"type":"turn.started"}'+[Environment]::NewLine+$Body)
    return $path
}
Test-Case 'completed turns sum tokens without double counting cached inputs' {
    $root=New-Fixture
    $log=Write-UsageLog $root
    Append-Utf8File $log ('{"type":"turn.started"}'+[Environment]::NewLine+'{"type":"turn.completed","usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":5}}')
    $usage=Get-CodexUsageFromLog $log 0
    Assert-True ($usage.status -eq 'known' -and $usage.input_tokens -eq 150 -and $usage.output_tokens -eq 25 -and $usage.completed_turns -eq 2) 'incorrect aggregate'
}
foreach($body in @('plain output','{"type":"turn.failed"}','{"type":"turn.completed","usage":{"input_tokens":-1,"cached_input_tokens":0,"output_tokens":1}}','{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":2,"output_tokens":1}}','{"type":"turn.completed","usage":{"input_tokens":"1","cached_input_tokens":0,"output_tokens":1}}','{"type":"turn.completed"','{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}')){
    Test-Case ('incomplete or malformed usage is unknown: '+$body) {
        $root=New-Fixture;$usage=Get-CodexUsageFromLog (Write-UsageLog $root $body) 0
        Assert-True ($usage.status -eq 'unknown' -and $null -eq $usage.input_tokens) 'unknown was reported as zero or known'
    }
}
Test-Case 'nonzero exit and truncated following turn invalidate complete accounting' {
    $root=New-Fixture;$log=Write-UsageLog $root
    Assert-True ((Get-CodexUsageFromLog $log 1).status -eq 'unknown') 'failure usage trusted'
    Append-Utf8File $log '{"type":"turn.started"}'
    Assert-True ((Get-CodexUsageFromLog $log 0).status -eq 'unknown') 'truncated turn trusted'
}
Test-Case 'zero and malformed policy fail closed before reservation' {
    foreach($policy in @(@{max_invocations=0},@{max_invocations=-1},@{max_invocations='2'},@{max_total_tokens=$true},@{max_total_token=1},@{billing_mode='free'})){
        $root=New-Fixture $policy;Assert-Rejected {New-HarnessUsageReservation $root (New-Record)}
        Assert-True (@(Read-HarnessUsageRecords $root).Count -eq 0) 'denied reservation persisted'
    }
}
Test-Case 'reservation survives reload and enforces invocation and retry counts' {
    $root=New-Fixture @{max_invocations=2;max_attempts_per_assignment=1}
    $record=New-Record;New-HarnessUsageReservation $root $record
    Assert-Rejected {New-HarnessUsageReservation $root $record}
    Assert-Rejected {New-HarnessUsageReservation $root (New-Record)}
    New-HarnessUsageReservation $root (New-Record 'second')
    Assert-Rejected {New-HarnessUsageReservation $root (New-Record 'third')}
    Assert-True (@(Read-HarnessUsageRecords $root).Count -eq 2) 'wrong reservation count'
}
Test-Case 'completed reservation records time and tokens, retains unknown billing and model facts' {
    $root=New-Fixture;$record=New-Record;New-HarnessUsageReservation $root $record
    Complete-HarnessUsageReservation $root $record (Write-UsageLog $root) 0 1.25
    $saved=@(Read-HarnessUsageRecords $root)[0];$totals=Get-HarnessUsageTotals @($saved)
    Assert-True ($totals.known_total_tokens -eq 120 -and $totals.completed_duration_seconds -eq 1.25 -and $totals.reserved_count -eq 0) 'wrong totals'
    Assert-True ($saved.requested_model -eq 'fixture-model' -and $null -eq $saved.resolved_model -and $saved.billing_mode -eq 'unknown' -and $null -eq $saved.actual_cost_usd) 'billing or model inferred'
    Assert-Rejected {Complete-HarnessUsageReservation $root $record (Write-UsageLog $root) 0 1.25}
}
Test-Case 'token threshold blocks unknown, concurrent and exhausted usage' {
    $root=New-Fixture @{max_total_tokens=100};$record=New-Record;New-HarnessUsageReservation $root $record
    Assert-Rejected {New-HarnessUsageReservation $root (New-Record 'second')}
    Complete-HarnessUsageReservation $root $record (Write-UsageLog $root) 0 1
    Assert-Rejected {New-HarnessUsageReservation $root (New-Record 'second')}
    $root=New-Fixture @{max_total_tokens=100};$record=New-Record;New-HarnessUsageReservation $root $record
    Complete-HarnessUsageReservation $root $record (Write-UsageLog $root 'plain output') 0 1
    Assert-Rejected {New-HarnessUsageReservation $root (New-Record 'second')}
}
Test-Case 'duration threshold and concurrency cap apply to subsequent launches' {
    $root=New-Fixture @{max_total_duration_seconds=2};$record=New-Record;New-HarnessUsageReservation $root $record
    Assert-Rejected {New-HarnessUsageReservation $root (New-Record 'second')}
    Complete-HarnessUsageReservation $root $record (Write-UsageLog $root) 0 3
    Assert-Rejected {New-HarnessUsageReservation $root (New-Record 'second')}
    $root=New-Fixture @{max_concurrent_workers=1};$record=New-Record;New-HarnessUsageReservation $root $record
    Assert-Rejected {New-HarnessUsageReservation $root (New-Record 'second')}
    Complete-HarnessUsageReservation $root $record (Write-UsageLog $root) 0 1
    New-HarnessUsageReservation $root (New-Record 'second')
}
Test-Case 'ledger identity and corrupt JSON fail closed' {
    $root=New-Fixture;$record=New-Record;New-HarnessUsageReservation $root $record
    $path=Join-Path (Get-HarnessUsageDirectory $root) ($record.invocation_id+'.json')
    $saved=[IO.File]::ReadAllText($path)|ConvertFrom-Json;$saved.root=$testRoot
    Write-Utf8File $path ($saved|ConvertTo-Json -Depth 8)
    Assert-Rejected {New-HarnessUsageReservation $root (New-Record)}
    Write-Utf8File $path '{broken'
    Assert-Rejected {Read-HarnessUsageRecords $root}
}
Test-Case 'fresh policy change applies without clearing profile cache' {
    $root=New-Fixture;Get-HarnessExecutionPolicy $root|Out-Null
    Write-Utf8File (Get-ProjectProfilePath $root) '{"execution_policy":{"max_invocations":0}}'
    Assert-Rejected {New-HarnessUsageReservation $root (New-Record)}
}
Test-Case 'usage command exposes structured report without provider billing assumptions' {
    $root=New-Fixture @{billing_mode='subscription'};$record=New-Record;New-HarnessUsageReservation $root $record
    Complete-HarnessUsageReservation $root $record (Write-UsageLog $root) 0 1
    $previous=$env:CODEX_HARNESS_ROOT
    try {
        $env:CODEX_HARNESS_ROOT=$root
        $r=Invoke-HarnessPowerShellFile (Join-Path $PSScriptRoot 'get_execution_usage.ps1') @('-Json') -AllowFailure
        Assert-True $r.Success $r.Output
        $report=$r.Output|ConvertFrom-Json
        Assert-True ($report.totals.invocation_count -eq 1 -and $report.invocations[0].billing_mode -eq 'subscription' -and $null -eq $report.invocations[0].actual_cost_usd) 'invalid report'
    } finally {$env:CODEX_HARNESS_ROOT=$previous}
}
Test-Case 'two competing processes cannot overbook last launch' {
    $root=New-Fixture @{max_invocations=1}
    $child=Join-Path $root 'reserve.ps1';$gate=Join-Path $root 'start'
    Write-Utf8File $child @'
param($Common,$Root,$Gate,$Result)
. $Common
while(-not(Test-Path -LiteralPath $Gate)){Start-Sleep -Milliseconds 10}
$record=[pscustomobject]@{invocation_id=[Guid]::NewGuid().ToString('N');assignment_id='race';owner='tester';arguments=@()}
try{New-HarnessUsageReservation $Root $record;Write-Utf8File $Result 'reserved'}catch{Write-Utf8File $Result 'denied'}
'@
    $children=@()
    try{
        foreach($index in 1..2){
            $info=New-Object Diagnostics.ProcessStartInfo
            $info.FileName=Get-HarnessPowerShellExecutable;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
            $arguments=@('-NoProfile');if(Test-HarnessIsWindows){$arguments+=@('-ExecutionPolicy','Bypass')}
            $arguments+=@('-File',$child,'-Common',(Join-Path $PSScriptRoot 'harness_common.ps1'),'-Root',$root,'-Gate',$gate,'-Result',(Join-Path $root "$index.result"))
            $info.Arguments=($arguments|ForEach-Object{'"'+$_.Replace('"','\"')+'"'}) -join ' '
            $children+= [Diagnostics.Process]::Start($info)
        }
        Write-Utf8File $gate 'go'
        foreach($process in $children){Assert-True ($process.WaitForExit(20000)) 'child did not finish'}
        $answers=@(1..2|ForEach-Object{[IO.File]::ReadAllText((Join-Path $root "$_.result")).Trim()})
        Assert-True (@($answers|Where-Object{$_ -eq 'reserved'}).Count -eq 1 -and @(Read-HarnessUsageRecords $root).Count -eq 1) 'last launch was overbooked'
    }finally{foreach($process in $children){if(-not $process.HasExited){$process.Kill();$process.WaitForExit()};$process.Dispose()}}
}
Write-Utf8File (Join-Path $testRoot 'results.json') ($results.ToArray()|ConvertTo-Json -Depth 5)
$failed=@($results|Where-Object{-not $_.passed}).Count
Write-Output "Usage results: $($results.Count-$failed)/$($results.Count) passed; artifacts: $testRoot"
if($failed){exit 1}
