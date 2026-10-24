param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$engine=Split-Path -Parent $PSScriptRoot
if(-not $OutputDirectory){$OutputDirectory=Join-Path $engine '.test-output'}
$testRoot=Join-Path $OutputDirectory ([Guid]::NewGuid().ToString('N'))
Ensure-HarnessDirectory $testRoot
$results=New-Object 'System.Collections.Generic.List[object]'
function Assert-True($Value,$Message){if(-not $Value){throw $Message}}
function Test-Case($Name,[scriptblock]$Body){try{& $Body;$results.Add(@{name=$Name;passed=$true});Write-Output "PASS $Name"}catch{$results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message});Write-Output "FAIL $Name : $($_.Exception.Message)"}}
function Snapshot($Root){
    $r=Invoke-HarnessPowerShellFile (Join-Path $PSScriptRoot 'get_harness_dashboard.ps1') @('-Root',$Root) -AllowFailure
    if(-not $r.Success){throw $r.Output}
    return ($r.Output|ConvertFrom-Json)
}
function New-Fixture($Layout){
    $root=Join-Path $testRoot ($Layout+' space [safe] & '+[Guid]::NewGuid().ToString('N'))
    $eng=if($Layout -eq 'nested'){Join-Path $root 'harness'}else{$root}
    Ensure-HarnessDirectory (Join-Path $eng 'scripts')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'harness_common.ps1') -Destination (Join-Path $eng 'scripts/harness_common.ps1')
    Write-Utf8File (Join-Path $eng 'project/configs/project_profile.json') '{"project":{"name":"Dashboard fixture"},"execution_policy":{"max_total_tokens":5000}}'
    Write-Utf8File (Join-Path $root 'source.txt') 'expected'
    Write-Utf8File (Join-Path $root 'validate.ps1') 'if ((Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "source.txt")).Trim() -ne "expected") { exit 7 }; Write-Output "assertion passed"'
    Invoke-HarnessProcess git @('init','-b','main',$root)|Out-Null
    Invoke-HarnessProcess git @('-C',$root,'add','source.txt','validate.ps1')|Out-Null
    Invoke-HarnessProcess git @('-C',$root,'-c','core.hooksPath=','-c','user.name=Fixture','-c','user.email=test@example.invalid','commit','-m','fixture')|Out-Null
    return $root
}
function Assignment($Root,$Id,$Bucket,$Result='pending',$Title='Fixture task'){
    $dir=(Get-AssignmentDirectories $Root 'tester')
    $content="- assignment_id: $Id`n- owner: tester`n- status: $Bucket`n- result: $Result`n- title: $Title`n- validation: pwsh -NoProfile -ExecutionPolicy Bypass -File validate.ps1`n"
    $file=if($Bucket -eq 'done'){$Id+'__'+$Result+'.md'}else{$Id+'.md'}
    Write-Utf8File (Join-Path (Join-Path $dir.Root $Bucket) $file) $content
    return $content
}
function FixtureFingerprint($Root){
    return (@(Get-ChildItem -LiteralPath $Root -Force -Recurse -File|Sort-Object FullName|ForEach-Object{$_.FullName+':'+(Get-EvidenceFileHash $_.FullName)}) -join '|')
}
. (Join-Path $PSScriptRoot 'harness_cli.ps1')
Test-Case 'CLI dashboard server preview uses fixed script and typed arguments' {
    $request=Get-HarnessCliRequest @('dashboard','-Port','0','-RefreshSeconds','5','-NoOpen','-Preview')
    $plan=Get-HarnessCliPlan $request $PSScriptRoot
    Assert-True ($plan.Script.EndsWith('start_harness_dashboard.ps1') -and $plan.Parameters.Port -eq 0 -and $plan.Parameters.NoOpen) 'invalid dashboard plan'
}
Test-Case 'CLI snapshot is structured and does not forward server switches' {
    $request=Get-HarnessCliRequest @('dashboard','-Snapshot','-Json')
    $plan=Get-HarnessCliPlan $request $PSScriptRoot
    Assert-True ($plan.Structured -and $plan.Script.EndsWith('get_harness_dashboard.ps1') -and -not $plan.Parameters.ContainsKey('Json') -and -not $plan.Parameters.ContainsKey('Snapshot')) 'invalid snapshot plan'
}
Test-Case 'CLI rejects invalid ports mixed options and server JSON' {
    foreach($tokens in @(@('dashboard','-Port','-1'),@('dashboard','-Port','65536'),@('dashboard','-RefreshSeconds','4'),@('dashboard','-Snapshot','-NoOpen'),@('dashboard','-Json'))){
        $rejected=$false;try{Get-HarnessCliRequest $tokens|Out-Null}catch{$rejected=$true}
        Assert-True $rejected ('accepted invalid options: '+($tokens -join ' '))
    }
}
Test-Case 'unconfigured checkout is truthful and read-only' {
    $before=Test-Path -LiteralPath (Join-Path $engine 'state')
    $s=Snapshot $engine
    Assert-True ($s.collection_status -eq 'ok' -and -not $s.project.configured -and $s.summary.total -eq 0) 'empty state not returned'
    Assert-True (@($s.alerts|Where-Object{$_.code -eq 'profile_missing'}).Count -eq 1) 'missing profile alert absent'
    Assert-True ((Test-Path -LiteralPath (Join-Path $engine 'state')) -eq $before) 'snapshot created state directory'
}
foreach($layout in @('standalone','nested')){
    $root=New-Fixture $layout
    $eng=Get-HarnessEngineRoot $root
    $null=Assignment $root 'queued' 'inbox'
    $null=Assignment $root 'active' 'in_progress'
    $null=Assignment $root 'failed' 'done' 'fail'
    $null=Assignment $root 'legacy' 'done' 'pass'
    Test-Case "$layout distinguishes queued failed unresolved and unverified" {
        $s=Snapshot $root
        Assert-True ($s.collection_status -eq 'ok' -and $s.summary.total -eq 4 -and $s.summary.passed -eq 0 -and $s.summary.unconfirmed -eq 2 -and $s.summary.failed -eq 1 -and $s.summary.queued -eq 1) 'incorrect queue counts'
    }
    $content=Assignment $root 'validated' 'in_progress'
    $e=New-AssignmentValidationEvidence $root 'tester' 'validated' $content
    $done=$content.Replace('- status: in_progress','- status: done').Replace('- result: pending','- result: pass')+"`n- validation_evidence: $($e.id)`n"
    $e.completed_assignment_hash=Get-HarnessTextHash $done
    Write-Utf8File (Join-Path (Get-AssignmentEvidenceDirectory $root) ($e.id+'.json')) ($e|ConvertTo-Json -Depth 10)
    $source=Join-Path $eng 'assignments/tester/in_progress/validated.md'
    [IO.File]::Move($source,(Join-Path $testRoot ($layout+'-original-assignment.md')))
    Write-Utf8File (Join-Path $eng 'assignments/tester/done/validated__pass.md') $done
    Test-Case "$layout verifies real completion without changing files or git objects" {
        $before=FixtureFingerprint $root;$s=Snapshot $root;$after=FixtureFingerprint $root
        Assert-True ($s.summary.passed -eq 1) 'real evidence not verified'
        Assert-True ($before -ceq $after) 'query mutated repository'
        Assert-True (-not [string]::IsNullOrEmpty(($s.tasks|Where-Object{$_.id -eq 'validated'}).validated_at)) 'evidence timestamp missing'
    }
    Test-Case "$layout source change invalidates previous completion" {
        Write-Utf8File (Join-Path $root 'source.txt') 'changed'
        Assert-True ((Snapshot $root).summary.passed -eq 0) 'stale source passed'
        Write-Utf8File (Join-Path $root 'source.txt') 'expected'
    }
    Test-Case "$layout staged index change invalidates completion" {
        Write-Utf8File (Join-Path $root 'source.txt') 'staged'
        Invoke-HarnessProcess git @('-C',$root,'add','source.txt')|Out-Null
        Write-Utf8File (Join-Path $root 'source.txt') 'expected'
        Assert-True ((Snapshot $root).summary.passed -eq 0) 'stale index passed'
        Invoke-HarnessProcess git @('-C',$root,'add','source.txt')|Out-Null
    }
    Test-Case "$layout active process identity and foreign host are distinct" {
        $record=[pscustomobject]@{version=1;root=$root;assignment_id='active';owner='tester';invocation_id=[Guid]::NewGuid().ToString('N');status='running';host=[Environment]::MachineName;worker_pid=$PID;worker_started_at=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');arguments=@();exit_code=$null}
        $nativeIdentity=Get-HarnessLinuxProcessIdentity $PID
        if(-not (Test-HarnessIsWindows)){Assert-True (-not [string]::IsNullOrWhiteSpace($nativeIdentity)) 'Linux process identity unavailable'}
        if($nativeIdentity){$record|Add-Member -NotePropertyName worker_process_identity -NotePropertyValue $nativeIdentity}
        $path=(Get-AssignmentWorkerPaths $root 'active').Record
        Write-Utf8File $path ($record|ConvertTo-Json -Depth 6)
        $s=Snapshot $root
        Assert-True ($s.summary.running_workers -eq 1 -and $s.summary.in_progress -eq 1) ('live process not observed; expected='+$record.worker_started_at+'; parent_observed='+(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')+'; workers='+($s.workers|ConvertTo-Json -Depth 4 -Compress)+'; alerts='+($s.alerts|ConvertTo-Json -Compress))
        $record.host='different-host';Write-Utf8File $path ($record|ConvertTo-Json -Depth 6)
        Assert-True ((Snapshot $root).summary.running_workers -eq 0) 'foreign pid accepted'
        $record.host=[Environment]::MachineName
        if($nativeIdentity){
            # Simulate wall-clock correction without changing kernel identity.
            $record.worker_started_at='2000-01-01T00:00:00Z';Write-Utf8File $path ($record|ConvertTo-Json -Depth 6)
            Assert-True ((Snapshot $root).summary.running_workers -eq 1) 'stable kernel identity lost after clock correction'
            $record.worker_process_identity=$nativeIdentity+'0';Write-Utf8File $path ($record|ConvertTo-Json -Depth 6)
            Assert-True ((Snapshot $root).summary.running_workers -eq 0) 'different kernel start accepted'
            $record.PSObject.Properties.Remove('worker_process_identity')
        }
        $record.worker_started_at='2000-01-01T00:00:00Z';Write-Utf8File $path ($record|ConvertTo-Json -Depth 6)
        Assert-True ((Snapshot $root).summary.running_workers -eq 0) 'recycled pid accepted'
    }
    Test-Case "$layout known unknown and pending usage remain separate" {
        $usageDir=Get-HarnessUsageDirectory $root
        foreach($kind in @('known','unknown','pending')){
            $id=[Guid]::NewGuid().ToString('N')
            $usage=if($kind -eq 'known'){@{status='known';input_tokens=100;cached_input_tokens=25;output_tokens=20}}else{@{status='unknown';input_tokens=$null;cached_input_tokens=$null;output_tokens=$null}}
            $r=@{version=1;root=$root;invocation_id=$id;assignment_id='active';owner='tester';attempt=1;provider='codex';requested_model=$null;billing_mode='unknown';status=$(if($kind -eq 'pending'){'reserved'}else{'completed'});reserved_at=[DateTime]::UtcNow.ToString('o');completed_at=$null;duration_seconds=2;usage=$usage}
            Write-Utf8File (Join-Path $usageDir ($id+'.json')) ($r|ConvertTo-Json -Depth 6)
        }
        $s=Snapshot $root
        Assert-True ($s.usage.totals.known_total_tokens -eq 120 -and $s.usage.totals.unknown_usage_count -eq 2 -and $s.usage.totals.reserved_count -eq 1) 'usage double-counted or unknown zeroed'
        Assert-True ($null -eq $s.usage.actual_cost_usd -and $null -eq $s.usage.subscription_remaining) 'billing inferred'
        Assert-True (@($s.alerts|Where-Object{$_.code -eq 'launch_unknown'}).Count -eq 1) 'unknown budget blocker absent'
    }
    Test-Case "$layout malformed usage is unavailable rather than zero" {
        $path=Join-Path (Get-HarnessUsageDirectory $root) 'bad.json';Write-Utf8File $path '{broken'
        $s=Snapshot $root;Assert-True ($s.usage.status -eq 'unavailable' -and $null -eq $s.usage.totals -and $s.collection_status -eq 'partial') 'corrupt ledger hidden'
        [IO.File]::Move($path,(Join-Path $testRoot ($layout+'-bad-usage.json')))
    }
    Test-Case "$layout cycle duplicate section keys and approvals are read correctly" {
        Write-Utf8File (Join-Path $eng 'reports/latest_report.md') "## Summary`n- status: fail`n## Results`n- build: pass`n- unit: fail`n- integration: not_run`n- benchmark_smoke: not_run`n## Logs`n- build: secret-output.log`n- unit: secret-unit.log`n"
        Write-Utf8File (Join-Path $eng 'state/git_workflow/state.json') '{"approvals":[{"id":"approval-1","status":"requested","source_branch":"test/example","target_branch":"main","requested_at":"2026-10-15T00:00:00Z"}]}'
        $s=Snapshot $root
        Assert-True ($s.validation.scope -eq 'last_completed_cycle' -and $s.validation.steps[0].status -eq 'pass' -and $s.validation.steps[1].status -eq 'fail' -and $s.summary.approval_requests -eq 1) 'cycle/approval parsing incorrect'
        Assert-True (-not ($s|ConvertTo-Json -Depth 20).Contains('secret-output.log')) 'raw log path exposed'
    }
    Test-Case "$layout pending queue transitions prevent completion counts" {
        $path=Join-Path $eng 'assignments/tester/.transitions/pending.json';Write-Utf8File $path '{"status":"pending"}'
        $s=Snapshot $root;Assert-True ($s.summary.passed -eq 0 -and $s.collection_status -eq 'partial') 'pending transition trusted'
        [IO.File]::Move($path,(Join-Path $testRoot ($layout+'-journal.json')))
    }
    Test-Case "$layout metadata cannot execute a command or leak raw prompt" {
        $null=Assignment $root 'literal' 'inbox' 'pending' '<img src=x onerror=alert(1)> $(Write-Output forbidden)'
        $path=Join-Path $eng 'assignments/tester/inbox/literal.md';Append-Utf8File $path "`n## Task`nRAW_PROMPT_PRIVATE_SENTINEL`n"
        $s=Snapshot $root;$json=$s|ConvertTo-Json -Depth 20
        Assert-True (-not $json.Contains('RAW_PROMPT_PRIVATE_SENTINEL') -and @($s.tasks|Where-Object{$_.id -eq 'literal'}).Count -eq 1) 'prompt leaked or metadata executed'
    }
    Test-Case "$layout configured path outside project is refused" {
        $profile=Join-Path $eng 'project/configs/project_profile.json';$previous=[IO.File]::ReadAllText($profile)
        try{Write-Utf8File $profile '{"harness":{"assignments_root":"../outside"}}';$s=Snapshot $root;Assert-True ($s.collection_status -eq 'partial') 'path escape accepted'}finally{Write-Utf8File $profile $previous}
    }
    Test-Case "$layout linked data directory is refused" {
        $target=Join-Path $testRoot ($layout+'-outside');Ensure-HarnessDirectory $target
        Write-Utf8File (Join-Path $target 'secret.md') 'PRIVATE_LINK_SENTINEL'
        $link=Join-Path $eng 'assignments/linked'
        $type=if(Test-HarnessIsWindows){'Junction'}else{'SymbolicLink'}
        New-Item -ItemType $type -Path $link -Target $target | Out-Null
        $s=Snapshot $root;Assert-True ($s.collection_status -eq 'partial' -and -not ($s|ConvertTo-Json -Depth 20).Contains('PRIVATE_LINK_SENTINEL')) 'linked directory followed'
    }
}
Write-Utf8File (Join-Path $testRoot 'results.json') ($results.ToArray()|ConvertTo-Json -Depth 6)
$failed=@($results|Where-Object{-not $_.passed})
Write-Output "Dashboard results: $($results.Count-$failed.Count)/$($results.Count) passed; artifacts: $testRoot"
if($failed.Count){exit 1}
