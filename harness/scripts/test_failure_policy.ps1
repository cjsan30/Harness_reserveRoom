param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$source=Split-Path -Parent $PSScriptRoot
if(-not $OutputDirectory){$OutputDirectory=Join-Path $source '.test-output'}
$testRoot=Join-Path $OutputDirectory ([Guid]::NewGuid().ToString('N'));Ensure-HarnessDirectory $testRoot
$results=New-Object 'System.Collections.Generic.List[object]'
function Assert-True($Value,[string]$Message){if(-not $Value){throw $Message}}
function Reject([scriptblock]$Body,[string]$Like=''){
    $message=$null;try{& $Body|Out-Null}catch{$message=$_.Exception.Message}
    Assert-True ($null -ne $message) 'expected rejection'
    if($Like){Assert-True ($message -like $Like) "unexpected rejection: $message"}
}
function Case([string]$Kind,[string]$Name,[scriptblock]$Body){try{& $Body;$results.Add(@{kind=$Kind;name=$Name;passed=$true});Write-Output "PASS [$Kind] $Name"}catch{$results.Add(@{kind=$Kind;name=$Name;passed=$false;error=$_.Exception.Message});Write-Output "FAIL [$Kind] $Name : $($_.Exception.Message)"}}
function Fixture($Policy=@{}){
    $root=Join-Path $testRoot ('failure [safe] '+[Guid]::NewGuid().ToString('N'))
    Write-Utf8File (Join-Path $root 'harness/project/configs/project_profile.json') (@{execution_policy=$Policy}|ConvertTo-Json -Depth 8)
    Ensure-HarnessDirectory (Join-Path $root 'harness/configs')
    Copy-Item -LiteralPath (Join-Path $source 'configs/known_errors.json') -Destination (Join-Path $root 'harness/configs/known_errors.json')
    return $root
}
function Worker([string]$Id='task',$Extra=@{}){
    $record=[pscustomobject]@{invocation_id=[Guid]::NewGuid().ToString('N');assignment_id=$Id;owner='tester';exit_code=0;timed_out=$false;provider_result=[pscustomobject]@{error_kind='none'};arguments=@('exec','--json','-m','fixture-model')}
    foreach($key in $Extra.Keys){$record|Add-Member -NotePropertyName $key -NotePropertyValue $Extra[$key] -Force}
    return $record
}
function Log([string]$Body){$path=Join-Path $testRoot ([Guid]::NewGuid().ToString('N')+'.log');Write-Utf8File $path $Body;return $path}
function Evidence([string]$Root,$Worker,[string]$Text){
    $directory=Get-AssignmentEvidenceDirectory $Root;$id=[Guid]::NewGuid().ToString('N')
    Write-Utf8File (Join-Path $directory ($id+'.log')) $Text
    Write-Utf8File (Join-Path $directory ($id+'.json')) (@{version=1;id=$id;assignment_id=$Worker.assignment_id;invocation_id=$Worker.invocation_id;status='fail';started_at=[DateTime]::UtcNow.ToString('o');log=(Get-RelativeProjectPath $Root (Join-Path $directory ($id+'.log')))}|ConvertTo-Json)
}
function Classify([string]$Root,$Worker,[string]$LogBody='',[string]$LastMessage=''){
    $log=if($LogBody){Log $LogBody}else{''}
    return Get-HarnessAttemptClassification (Get-HarnessKnownErrorCatalog $Root) (Get-HarnessAttemptFacts $Root $Worker $log $LastMessage)
}
function Reserve([string]$Root,[string]$Id='task'){
    $worker=Worker $Id;New-HarnessUsageReservation $Root $worker
    Complete-HarnessUsageReservation $Root $worker (Log '{"type":"turn.started"}') 1 1
    return $worker
}
$denied='{"type":"result","subtype":"success","is_error":false,"session_id":"s","result":"blocked","terminal_reason":"completed","usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1},"permission_denials":[{"tool_name":"Bash","tool_input":{"command":"./gradlew test"}}]}'
function ErrorResult([string]$Text){return '{"type":"result","subtype":"success","is_error":true,"session_id":"s","result":'+($Text|ConvertTo-Json)+'}'}

Case unit 'catalog loads engine defaults and a project entry replaces one by id' {
    $root=Fixture
    $catalog=@(Get-HarnessKnownErrorCatalog $root)
    Assert-True (@($catalog|Where-Object{$_.id -eq 'docker-unavailable' -and $_.repair -eq 'docker-start'}).Count -eq 1) 'engine Docker entry missing'
    $project=@{version=1;entries=@(@{id='docker-unavailable';class='environment';sources=@('validation');match_any=@('custom docker text');repair=$null},@{id='redis-down';class='environment';sources=@('validation');match_any=@('Connection refused: localhost/127.0.0.1:6379')})}
    Write-Utf8File (Join-Path $root 'harness/project/configs/known_errors.json') ($project|ConvertTo-Json -Depth 6)
    $catalog=@(Get-HarnessKnownErrorCatalog $root)
    $docker=@($catalog|Where-Object{$_.id -eq 'docker-unavailable'})
    Assert-True ($docker.Count -eq 1 -and $null -eq $docker[0].repair -and @($catalog|Where-Object{$_.id -eq 'redis-down'}).Count -eq 1) 'project entries not applied'
}
Case security 'malformed catalog entries are refused' {
    foreach($entry in @(
        @{id='x-bad';class='implementation';sources=@('validation');match_any=@('some text')},
        @{id='x-bad';class='environment';sources=@('validation');match_any=@('ab')},
        @{id='x-bad';class='environment';sources=@('stdin');match_any=@('some text')},
        @{id='x-bad';class='provider';sources=@('provider');match_any=@('some text')},
        @{id='x-bad';class='environment';sources=@('validation');match_any=@('some text');run='rm -rf /'},
        @{id='../escape';class='environment';sources=@('validation');match_any=@('some text')})){
        $root=Fixture
        Write-Utf8File (Join-Path $root 'harness/project/configs/known_errors.json') (@{version=1;entries=@($entry)}|ConvertTo-Json -Depth 6)
        Reject {Get-HarnessKnownErrorCatalog $root}
    }
}
Case unit 'signature ignores paths and line numbers but separates different errors' {
    $a=Get-HarnessFailureSignature "BUILD FAILED`nC:\work\one\src\main\java\Foo.java:12: error: cannot find symbol`n  symbol: class Bar"
    $b=Get-HarnessFailureSignature "BUILD FAILED`n/home/ci/two/src/main/java/Foo.java:48: error: cannot find symbol`n  symbol: class Bar"
    $c=Get-HarnessFailureSignature "SeedAdminMigrationTests > seedsAdmin() FAILED`n    org.opentest4j.AssertionFailedError: expected: <1> but was: <0>"
    Assert-True ($a.id -eq $b.id) 'same error got different signatures'
    Assert-True ($a.id -ne $c.id) 'different errors got the same signature'
    Assert-True (-not ($a.lines -join ' ').Contains('work')) 'directory names kept in signature'
}
Case unit 'permission denials stop without counting and name the denied command' {
    $root=Fixture;$c=Classify $root (Worker) $denied
    Assert-True ($c.class -eq 'permission' -and -not $c.counts_toward_assignment_limit -and ($c.details -join ' ').Contains('./gradlew test')) "wrong: $($c|ConvertTo-Json -Compress)"
    Assert-True ((Get-HarnessFailureDecision $c ([pscustomobject]@{attempts=@()})).action -eq 'stop_needs_operator') 'permission did not stop'
}
Case unit 'provider usage limit stops as a budget stop and outages are retried' {
    $root=Fixture
    $limit=Classify $root (Worker -Extra @{provider_result=[pscustomobject]@{error_kind='provider_error'}}) (ErrorResult 'Claude AI usage limit reached, resets 3pm')
    Assert-True ($limit.class -eq 'provider' -and $limit.kind -eq 'usage_limit' -and -not $limit.counts_toward_assignment_limit) 'usage limit not recognized'
    Assert-True ((Get-HarnessFailureDecision $limit ([pscustomobject]@{attempts=@()})).action -eq 'stop_budget') 'usage limit did not stop as budget'
    $busy=Classify $root (Worker -Extra @{provider_result=[pscustomobject]@{error_kind='provider_error'}}) (ErrorResult 'API Error: 529 {"type":"error","error":{"type":"overloaded_error"}}')
    Assert-True ($busy.kind -eq 'overloaded' -and (Get-HarnessFailureDecision $busy ([pscustomobject]@{attempts=@()})).action -eq 'provider_retry') 'outage not retried'
    $auth=Classify $root (Worker -Extra @{provider_result=[pscustomobject]@{error_kind='provider_error'}}) (ErrorResult 'Invalid API key · Please run /login')
    Assert-True ($auth.kind -eq 'auth' -and (Get-HarnessFailureDecision $auth ([pscustomobject]@{attempts=@()})).action -eq 'stop_needs_operator') 'auth problem was retried'
}
Case security 'provider texts in tool output or a normal result are not provider failures' {
    $root=Fixture;$worker=Worker
    $tool='{"type":"user","message":{"content":[{"type":"tool_result","content":"usage limit reached; API Error: 529"}]}}'
    $c=Classify $root $worker ($tool+"`n"+'{"type":"result","subtype":"success","is_error":false,"session_id":"s","result":"usage limit reached","permission_denials":[]}')
    Assert-True ($c.class -eq 'implementation') "worker text changed the class: $($c.class)"
}
Case unit 'idle timeout is an environment hang and a busy timeout counts' {
    $root=Fixture
    $hung=Classify $root (Worker -Extra @{timed_out=$true;idle_seconds_at_exit=900;exit_code=124})
    $busy=Classify $root (Worker -Extra @{timed_out=$true;idle_seconds_at_exit=12;exit_code=124})
    Assert-True ($hung.class -eq 'environment' -and $hung.kind -eq 'hung_command' -and -not $hung.counts_toward_assignment_limit) 'idle timeout counted'
    Assert-True ($busy.class -eq 'implementation' -and $busy.kind -eq 'timeout' -and $busy.counts_toward_assignment_limit) 'busy timeout not counted'
}
Case unit 'known environment errors in the validation log name their repair' {
    $root=Fixture;$worker=Worker
    Evidence $root $worker "Caused by: java.lang.IllegalStateException: Could not find a valid Docker environment. Please see logs"
    $c=Classify $root $worker
    Assert-True ($c.class -eq 'environment' -and $c.catalog_id -eq 'docker-unavailable' -and $c.repair -eq 'docker-start' -and -not $c.counts_toward_assignment_limit) "wrong: $($c|ConvertTo-Json -Compress)"
}
Case unit 'missing information marker stops without counting' {
    $root=Fixture
    $c=Classify $root (Worker) '' "HARNESS_NEEDS_INPUT: the BCrypt hash for the seeded admin password`nI stopped."
    Assert-True ($c.class -eq 'needs_input' -and ($c.details -join '').Contains('BCrypt') -and -not $c.counts_toward_assignment_limit) 'needs input not recognized'
}
Case unit 'failed validation counts and repeats stop early' {
    $root=Fixture
    $first=Worker;Evidence $root $first "Foo.java:12: error: cannot find symbol"
    $saved=Save-HarnessAttemptClassification $root $first (Classify $root $first)
    Assert-True ($saved.class -eq 'implementation' -and $saved.counts_toward_assignment_limit -and $saved.signature) 'validation failure not counted'
    Assert-True ((Get-HarnessFailureDecision $saved (Read-HarnessFailureHistory $root 'task')).action -eq 'retry') 'first failure did not retry'
    $second=Worker;Evidence $root $second "Foo.java:40: error: cannot find symbol"
    $repeat=Save-HarnessAttemptClassification $root $second (Classify $root $second)
    Assert-True ((Get-HarnessFailureDecision $repeat (Read-HarnessFailureHistory $root 'task')).action -eq 'stop_repeated') 'repeated failure was retried'
    $third=Worker;Evidence $root $third "BarTests > works() FAILED`nAssertionFailedError: expected: <1> but was: <2>"
    $other=Save-HarnessAttemptClassification $root $third (Classify $root $third)
    Assert-True ((Get-HarnessFailureDecision $other (Read-HarnessFailureHistory $root 'task')).action -eq 'retry') 'a new failure was not retried'
}
Case integration 'only implementation failures use up attempts and grants add more' {
    $root=Fixture @{max_attempts_per_assignment=2}
    $a=Reserve $root;$null=Save-HarnessAttemptClassification $root $a (New-HarnessFailureClassification 'permission' 'denied' 'denied')
    $b=Reserve $root;$null=Save-HarnessAttemptClassification $root $b (New-HarnessFailureClassification 'environment' 'docker-unavailable' 'docker')
    $c=Reserve $root
    $status=Get-HarnessAssignmentAttemptStatus $root 'task'
    Assert-True ($status.invocations -eq 3 -and $status.counted -eq 1 -and $status.remaining -eq 1) "wrong status: $($status|ConvertTo-Json -Compress)"
    $d=Reserve $root
    Reject {New-HarnessUsageReservation $root (Worker)} '*max_attempts_per_assignment (2 of 2 counted attempts used for task; grant more with*'
    $null=Add-HarnessAttemptGrant $root 'task' 1 'reviewed the failure and fixed the requirement'
    New-HarnessUsageReservation $root (Worker)
    Assert-True ((Get-HarnessAssignmentAttemptStatus $root 'task').limit -eq 3) 'grant not applied'
    Assert-True ((Get-HarnessAssignmentAttemptStatus $root 'other').counted -eq 0) 'grant or count leaked to another assignment'
}
Case security 'grants and failure history fail closed when invalid' {
    $root=Fixture @{max_attempts_per_assignment=1}
    Reject {Add-HarnessAttemptGrant $root 'task' 0 'reason'}
    Reject {Add-HarnessAttemptGrant $root 'task' 11 'reason'}
    Reject {Add-HarnessAttemptGrant $root 'task' 1 '  '}
    Reject {Add-HarnessAttemptGrant $root '../task' 1 'reason'}
    $worker=Reserve $root;$null=Save-HarnessAttemptClassification $root $worker (New-HarnessFailureClassification 'permission' 'denied' 'denied')
    $path=Join-Path (Get-HarnessFailureStateDirectory $root) 'task.json'
    $history=[IO.File]::ReadAllText($path)|ConvertFrom-Json;$history.attempts[0].counts_toward_assignment_limit=$false;$history.attempts[0].class='implementation'
    Write-Utf8File $path ($history|ConvertTo-Json -Depth 8)
    Reject {New-HarnessUsageReservation $root (Worker)}
    Write-Utf8File $path '{broken'
    Reject {Get-HarnessAssignmentAttemptStatus $root 'task'}
}
Case unit 'global budget refusals say which limit and how much was used' {
    $root=Fixture @{max_invocations=1};$null=Reserve $root
    Reject {New-HarnessUsageReservation $root (Worker 'next')} '*execution budget reached: max_invocations (1 of 1 invocations used)*'
    $root=Fixture @{max_total_duration_seconds=1};$null=Reserve $root
    Reject {New-HarnessUsageReservation $root (Worker 'next')} '*execution budget reached: max_total_duration_seconds (1 of 1 seconds used)*'
}
Case unit 'classification errors fall back to a counted failure' {
    $root=Fixture;$worker=Worker
    Write-Utf8File (Join-Path $root 'harness/project/configs/known_errors.json') '{broken'
    $saved=Invoke-HarnessAttemptClassification $root $worker (Log $denied)
    Assert-True ($saved.class -eq 'implementation' -and $saved.kind -eq 'unclassified' -and $saved.counts_toward_assignment_limit) 'classification error was not counted'
}

Case integration 'a real invocation records its class, summary and its own log copy' {
    $root=Join-Path $testRoot ('invoke [safe] '+[Guid]::NewGuid().ToString('N'));$engine=Join-Path $root 'harness'
    Ensure-HarnessDirectory $engine
    foreach($dir in @('scripts','configs')){Copy-Item -LiteralPath (Join-Path $source $dir) -Destination (Join-Path $engine $dir) -Recurse}
    $profile=[IO.File]::ReadAllText((Join-Path $source 'configs/project_profile.template.json'))|ConvertFrom-Json
    $profile.worker_provider.name='claude'
    Write-Utf8File (Join-Path $engine 'project/configs/project_profile.json') ($profile|ConvertTo-Json -Depth 20)
    Invoke-HarnessProcess git @('init','-b','main',$root)|Out-Null
    Write-Utf8File (Join-Path $root 'baseline.txt') 'fixture'
    Invoke-HarnessProcess git @('-C',$root,'add','baseline.txt')|Out-Null
    Invoke-HarnessProcess git @('-C',$root,'-c','core.hooksPath=','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-m','fixture')|Out-Null
    $dirs=Get-AssignmentDirectories $root 'tester'
    Write-Utf8File (Join-Path $dirs.Inbox 'task.md') "- assignment_id: task`n- status: inbox`n- result: pending`n- validation: git cat-file -e HEAD:baseline.txt`n"
    Write-Utf8File (Join-Path $engine 'reports/dispatch_packets/task.md') 'fixture prompt'
    $fake=Join-Path $root 'fake-claude.ps1'
    Write-Utf8File $fake ("if(`$args -contains '--version'){'fake Claude';return}`n`$null=@(`$input)`n'"+$denied+"'")
    $oldRoot=$env:CODEX_HARNESS_ROOT;$oldPath=$env:HARNESS_CLAUDE_PATH;$oldWorkspace=$env:CODEX_GIT_WORKSPACE_ROOT
    try{
        $env:CODEX_HARNESS_ROOT=$root;$env:HARNESS_CLAUDE_PATH=$fake;$env:CODEX_GIT_WORKSPACE_ROOT=$null
        $r=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/invoke_assignment_codex.ps1') @('-Agent','tester','-AssignmentId','task') -AllowFailure
        Assert-True (-not $r.Success) 'denied run succeeded'
        $worker=Get-AssignmentWorkerRecord $root 'task'
        $history=Read-HarnessFailureHistory $root 'task'
        Assert-True (@($history.attempts).Count -eq 1 -and $history.attempts[0].class -eq 'permission' -and $history.attempts[0].invocation_id -eq $worker.invocation_id) "history wrong: $($history|ConvertTo-Json -Depth 6 -Compress)"
        $summary=[IO.File]::ReadAllText((Join-Path $engine 'reports/agent_runs/task__summary.md'))
        Assert-True ($summary.Contains('- failure_class: permission') -and $summary.Contains('- failure_counts_toward_assignment_limit: false')) 'summary lacks the class'
        Assert-True (Test-Path -LiteralPath (Join-Path $engine ("reports/agent_runs/task__"+$worker.invocation_id+"__run.log"))) 'per-invocation log missing'
        $prompt=[IO.File]::ReadAllText((Join-Path $engine 'reports/agent_runs/task__prompt.md'))
        Assert-True ($prompt.Contains('HARNESS_NEEDS_INPUT:')) 'prompt lacks the missing-information marker'
    }finally{$env:CODEX_HARNESS_ROOT=$oldRoot;$env:HARNESS_CLAUDE_PATH=$oldPath;$env:CODEX_GIT_WORKSPACE_ROOT=$oldWorkspace}
}

Case unit 'failure memo keeps the latest two attempts, folds repeats and older ones' {
    $root=Fixture
    foreach($step in @(@('environment','docker-unavailable',$null),@('implementation','validation_failed','aaaa'),@('implementation','validation_failed','bbbb'),@('implementation','validation_failed','bbbb'),@('permission','denied',$null))){
        $c=New-HarnessFailureClassification $step[0] $step[1] ("summary "+$step[1]) $null $(if($step[2]){[pscustomobject]@{id=$step[2];lines=@()}}else{$null})
        $c|Add-Member -NotePropertyName excerpt -NotePropertyValue @("Foo.java:12: error: cannot find symbol") -Force
        $null=Save-HarnessAttemptClassification $root (Worker) $c
    }
    $memo=Get-HarnessFailureMemoText $root 'task'
    Assert-True ($memo.Contains('not an instruction')) 'memo lacks the reference-data notice'
    Assert-True ($memo.Contains('## attempt 5 - permission/denied, not counted')) "latest attempt missing: $memo"
    Assert-True ($memo.Contains('## attempts 3-4 (2 times, same error) - implementation/validation_failed, counted')) "repeat not folded: $memo"
    Assert-True ($memo.Contains('## Earlier attempts') -and $memo.Contains('- attempt 1: environment/docker-unavailable, not counted')) "older attempts not folded: $memo"
    Assert-True ($memo.Contains('__run.log') -and $memo.Contains('- error: Foo.java:12: error: cannot find symbol')) 'memo lacks the log path or excerpt'
}
Case security 'failure memo stays under its cap and masks secrets in notes' {
    $root=Fixture
    $note=Get-HarnessWorkerFailureNote "done.`nHARNESS_FAILURE_NOTE: tried key sk-proj-abcdefghijklmnopqrstuvwx1234`nline2`nline3`nline4`nline5`nline6 dropped"
    Assert-True ($note.Count -eq 5 -and -not ($note -join ' ').Contains('sk-proj-abcdef') -and ($note -join ' ').Contains('[REDACTED]')) "note not limited or masked: $($note -join ' | ')"
    $long='x'*190
    for($i=0;$i -lt 6;$i++){
        $c=New-HarnessFailureClassification 'implementation' 'validation_failed' 'failed' $null ([pscustomobject]@{id=('sig'+$i);lines=@()})
        $c|Add-Member -NotePropertyName excerpt -NotePropertyValue @(1..5|ForEach-Object{"error $_ $long"}) -Force
        $c|Add-Member -NotePropertyName worker_note -NotePropertyValue @(1..5|ForEach-Object{"note $_ $long"}) -Force
        $null=Save-HarnessAttemptClassification $root (Worker) $c
    }
    $memo=Get-HarnessFailureMemoText $root 'task'
    Assert-True ($memo.Length -le 2020 -and $memo.Contains('## attempt 6')) "memo too long ($($memo.Length)) or lost the latest attempt"
}

# Dispatcher decisions: the production retry loop is loaded without running dispatch.
$dispatchAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'dispatch_seed_plan.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Get-LatestAttemptFailure','New-WorkerOutcome','Invoke-AssignmentWorkerWithRetry')){
    $definition=$dispatchAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$DryRun=$false;$PreflightOnly=$false;$ProviderRetryDelaySeconds=0;$providerRetryLimit=2
$script:scenario=$null;$script:launches=0;$script:requeues=0
$script:lifecycleFile=$null
function Get-AssignmentLifecycleRecord($Owner,$AssignmentId){if($script:lifecycleFile){return [pscustomobject]@{State='done';Result='fail';File=$script:lifecycleFile}};return [pscustomobject]@{State='done';Result=$script:lastResult}}
function Requeue-FailedAssignment($Owner,$AssignmentId,$NextAttempt,$FailureContext){$script:requeues++}
function Invoke-AssignmentWorker($Owner,$CurrentAssignmentId){
    $step=$script:scenario[$script:launches];$script:launches++
    if($step -eq 'budget'){$script:lastResult='pending';return [pscustomobject]@{Success=$false;ExitCode=1;Output='execution budget reached: max_invocations (12 of 12 invocations used)'}}
    if($step -eq 'pass'){$script:lastResult='pass';return [pscustomobject]@{Success=$true;ExitCode=0;Output='ok'}}
    $worker=Worker $CurrentAssignmentId;$worker|Add-Member -NotePropertyName version -NotePropertyValue 1 -Force
    $worker|Add-Member -NotePropertyName root -NotePropertyValue ([IO.Path]::GetFullPath($rootDir)) -Force
    $worker|Add-Member -NotePropertyName status -NotePropertyValue 'settled' -Force
    Write-Utf8File (Get-AssignmentWorkerPaths $rootDir $CurrentAssignmentId).Record ($worker|ConvertTo-Json -Depth 6)
    $classification=switch -Wildcard ($step){
        'impl:*'{New-HarnessFailureClassification 'implementation' 'validation_failed' 'failed' $null ([pscustomobject]@{id=$step.Substring(5);lines=@()})}
        'permission'{New-HarnessFailureClassification 'permission' 'denied' 'denied'}
        'overloaded'{New-HarnessFailureClassification 'provider' 'overloaded' 'busy'}
        'usage_limit'{New-HarnessFailureClassification 'provider' 'usage_limit' 'limit'}
    }
    $null=Save-HarnessAttemptClassification $rootDir $worker $classification
    $script:lastResult='fail'
    return [pscustomobject]@{Success=$false;ExitCode=1;Output='worker failed'}
}
function Run-Scenario([string[]]$Steps,[int]$MaxAttempts=3){
    $script:rootDir=Fixture;$script:scenario=$Steps;$script:launches=0;$script:requeues=0;$script:MaxWorkerAttempts=$MaxAttempts
    return Invoke-AssignmentWorkerWithRetry -Owner 'tester' -AssignmentId 'task'
}
Case integration 'budget refusal stops the plan with the limit instead of a requeue error (F-20)' {
    $o=Run-Scenario @('budget')
    Assert-True ($o.StopKind -eq 'budget' -and $o.StopReason.Contains('max_invocations (12 of 12') -and $script:requeues -eq 0 -and $o.Attempts -eq 0) "wrong: $($o|ConvertTo-Json -Compress)"
}
Case integration 'permission failure stops after one launch' {
    $o=Run-Scenario @('permission','pass')
    Assert-True ($o.StopKind -eq 'needs_operator' -and $script:launches -eq 1 -and $o.FailureClass -eq 'permission') "wrong: $($o|ConvertTo-Json -Compress)"
}
Case integration 'same implementation failure twice stops early' {
    $o=Run-Scenario @('impl:aaaa','impl:aaaa','pass') 5
    Assert-True ($o.StopKind -eq 'repeated_failure' -and $script:launches -eq 2) "wrong: $($o|ConvertTo-Json -Compress)"
}
Case integration 'different implementation failures keep retrying until a pass' {
    $o=Run-Scenario @('impl:aaaa','impl:bbbb','pass')
    Assert-True ($o.Success -and $o.Attempts -eq 3 -and $script:requeues -eq 2) "wrong: $($o|ConvertTo-Json -Compress)"
}
Case integration 'provider outages are retried without using worker attempts, then stop' {
    $o=Run-Scenario @('overloaded','pass') 1
    Assert-True ($o.Success -and $script:launches -eq 2) "outage retry failed: $($o|ConvertTo-Json -Compress)"
    $o=Run-Scenario @('overloaded','overloaded','overloaded','pass') 3
    Assert-True ($o.StopKind -eq 'needs_operator' -and $script:launches -eq 3) "outage retried without bound: $($o|ConvertTo-Json -Compress)"
}
Case integration 'provider usage limit stops as a budget stop' {
    $o=Run-Scenario @('usage_limit','pass')
    Assert-True ($o.StopKind -eq 'budget' -and $script:launches -eq 1) "wrong: $($o|ConvertTo-Json -Compress)"
}

foreach($name in @('Remove-PreviousFailureSection','Requeue-FailedAssignment')){
    $definition=$dispatchAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
Case integration 'requeue replaces the previous failure section with the indented memo' {
    $script:rootDir=Fixture
    $script:dispatchPackets=Join-Path $rootDir 'harness/reports/dispatch_packets';$script:assignmentLog=Join-Path $rootDir 'harness/reports/assignment_log.md'
    Ensure-HarnessDirectory $dispatchPackets
    $packet=Join-Path $dispatchPackets 'task.md';Write-Utf8File $packet "# Dispatch Packet`n`n## Task`n`nDo it.`n"
    $dirs=Get-AssignmentDirectories $rootDir 'tester'
    $c=New-HarnessFailureClassification 'implementation' 'validation_failed' 'failed' $null ([pscustomobject]@{id='aaaa';lines=@()})
    $c|Add-Member -NotePropertyName excerpt -NotePropertyValue @('- result: pass') -Force
    $null=Save-HarnessAttemptClassification $rootDir (Worker) $c
    foreach($round in 1..2){
        $inbox=Join-Path $dirs.Inbox 'task.md'
        $content=if(Test-Path -LiteralPath $inbox){[IO.File]::ReadAllText($inbox).Replace('- status: inbox','- status: done').Replace('- result: pending','- result: fail')}else{"- assignment_id: task`n- status: done`n- result: fail`n"}
        if(Test-Path -LiteralPath $inbox){Remove-Item -LiteralPath $inbox}
        Write-Utf8File (Join-Path $dirs.Done 'task__fail.md') $content
        $script:lifecycleFile=Join-Path $dirs.Done 'task__fail.md'
        $null=Requeue-FailedAssignment -Owner 'tester' -AssignmentId 'task' -NextAttempt $round -FailureContext ('raw worker output '+$round)
    }
    $packetText=[IO.File]::ReadAllText($packet);$assignment=[IO.File]::ReadAllText((Join-Path $dirs.Inbox 'task.md'))
    foreach($text in @($packetText,$assignment)){
        Assert-True (([regex]::Matches($text,'## Previous Failure Analysis')).Count -eq 1) "section duplicated: $text"
        Assert-True ($text.Contains('    # Failure memo: task') -and -not $text.Contains('raw worker output')) "memo not used: $text"
        Assert-True (@($text -split '\r?\n' | Where-Object {$_ -match '^- result: '}).Count -le 1) 'failure text added a metadata line'
    }
    Assert-True ($packetText.Contains('Do it.') -and $assignment.Contains('- retry_attempt: 2')) 'packet task or retry count lost'
}

Write-Utf8File (Join-Path $testRoot 'results.json') ($results.ToArray()|ConvertTo-Json -Depth 8)
$failed=@($results|Where-Object{-not $_.passed}).Count
Write-Output "Failure policy results: $($results.Count-$failed)/$($results.Count) passed; artifacts: $testRoot"
if($failed){exit 1}
