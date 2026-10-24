param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$source=Split-Path -Parent $PSScriptRoot
if(-not $OutputDirectory){$OutputDirectory=Join-Path $source '.test-output'}
$testRoot=Join-Path $OutputDirectory ([Guid]::NewGuid().ToString('N'));Ensure-HarnessDirectory $testRoot
$results=New-Object 'System.Collections.Generic.List[object]'
function Assert-True($Value,[string]$Message){if(-not $Value){throw $Message}}
function Reject([scriptblock]$Body){$blocked=$false;try{& $Body|Out-Null}catch{$blocked=$true};Assert-True $blocked 'expected rejection'}
function Case([string]$Kind,[string]$Name,[scriptblock]$Body){try{& $Body;$results.Add(@{kind=$Kind;name=$Name;passed=$true});Write-Output "PASS [$Kind] $Name"}catch{$results.Add(@{kind=$Kind;name=$Name;passed=$false;error=$_.Exception.Message});Write-Output "FAIL [$Kind] $Name : $($_.Exception.Message)"}}
function Fixture($Profile=@{}){
    $root=Join-Path $testRoot ('claude [safe] '+[Guid]::NewGuid().ToString('N'))
    Write-Utf8File (Join-Path $root 'harness/project/configs/project_profile.json') ($Profile|ConvertTo-Json -Depth 20)
    return $root
}
function Record([string]$Provider='claude'){
    return [pscustomobject]@{invocation_id=[Guid]::NewGuid().ToString('N');owner='tester';assignment_id='task';arguments=@();provider_contract=[pscustomobject]@{version=1;provider=$Provider;requested_model='fixture-model'}}
}
function Log([string]$Body){$path=Join-Path $testRoot ([Guid]::NewGuid().ToString('N')+'.log');Write-Utf8File $path $Body;return $path}
$valid='{"type":"result","subtype":"success","is_error":false,"session_id":"fixture-session","num_turns":3,"result":"done","usage":{"input_tokens":10,"cache_read_input_tokens":40,"cache_creation_input_tokens":50,"output_tokens":20},"permission_denials":[]}'
Case unit 'profile selects Claude and absent selection still selects Codex' {
    Assert-True ((Get-HarnessConfiguredProvider (Fixture @{worker_provider=@{version=1;name='claude'}})) -ceq 'claude') 'Claude not selected'
    Assert-True ((Get-HarnessConfiguredProvider (Fixture)) -ceq 'codex') 'legacy selection changed'
}
Case security 'launch preserves literal model and denies permission bypass without executing' {
    $fake=Join-Path $testRoot 'fake cli.ps1';Write-Utf8File $fake 'throw "planning executed provider"'
    $old=$env:HARNESS_CLAUDE_PATH
    try{
        $env:HARNESS_CLAUDE_PATH=$fake;$model='fixture; $(never) "quoted"'
        $launch=New-HarnessProviderLaunch 'claude' $testRoot 'unused.txt' $model -Ephemeral
        $expected=@('--print','--input-format','text','--output-format','stream-json','--verbose','--permission-mode','acceptEdits','--permission-prompts','none','--no-session-persistence','--model',$model)
        Assert-True (($launch.arguments|ConvertTo-Json -Compress) -ceq ($expected|ConvertTo-Json -Compress)) 'unsafe or malformed arguments'
        Assert-True ($launch.executable -eq $fake -and $launch.contract.provider -eq 'claude') 'wrong executable'
        $blank=New-HarnessProviderLaunch 'claude' $testRoot 'unused.txt' '  '
        Assert-True ($null -eq $blank.contract.requested_model -and $blank.arguments -notcontains '--model' -and $blank.arguments -notcontains '--no-session-persistence') 'blank model or persistence wrong'
    }finally{$env:HARNESS_CLAUDE_PATH=$old}
}
Case security 'missing Claude never falls back to Codex' {
    $old=$env:HARNESS_CLAUDE_PATH;$oldCodex=$env:HARNESS_CODEX_PATH
    try{$env:HARNESS_CLAUDE_PATH=Join-Path $testRoot 'missing.exe';$env:HARNESS_CODEX_PATH=(Get-HarnessPowerShellExecutable);Reject {New-HarnessProviderLaunch 'claude' $testRoot 'unused.txt' ''}}
    finally{$env:HARNESS_CLAUDE_PATH=$old;$env:HARNESS_CODEX_PATH=$oldCodex}
}
Case unit 'aggregate includes cache creation and cache reads exactly once' {
    $body='{"type":"system","subtype":"init","session_id":"fixture-session"}'+"`n"+'{"type":"assistant","message":{"usage":{"input_tokens":999999}}}'+"`n"+$valid
    $worker=Record;$r=Get-HarnessProviderResult $worker (Log $body) 0
    Assert-HarnessProviderResult $r $worker.provider_contract $worker.invocation_id 0
    Assert-True ($r.execution_status -eq 'succeeded' -and $r.usage.input_tokens -eq 100 -and $r.usage.cached_input_tokens -eq 40 -and $r.usage.output_tokens -eq 20 -and $r.usage.completed_turns -eq 1) 'aggregate miscounted'
    Assert-True ($null -eq $r.resolved_model) 'model inferred'
}
foreach($mode in @('missing_usage','missing_cache','negative','string','fraction','boolean','overflow')){
    Case unit ("unknown token counts are not zero: $mode") {
        $e=$valid|ConvertFrom-Json
        switch($mode){
            missing_usage{$e.usage=$null}
            missing_cache{$e.usage.PSObject.Properties.Remove('cache_creation_input_tokens')}
            negative{$e.usage.input_tokens=-1}
            string{$e.usage.input_tokens='10'}
            fraction{$e.usage.input_tokens=1.5}
            boolean{$e.usage.input_tokens=$true}
            overflow{$e.usage.input_tokens=[long]::MaxValue}
        }
        $r=Get-HarnessProviderResult (Record) (Log ($e|ConvertTo-Json -Depth 12 -Compress)) 0
        Assert-True ($r.response_status -eq 'completed' -and $r.usage.status -eq 'unknown' -and $null -eq $r.usage.input_tokens -and $null -eq $r.usage.output_tokens) 'invalid counts accepted'
    }
}
foreach($mode in @('error_flag','error_subtype','denial_list','denial_event','errors','aborted','error_event','exit','missing','truncated','duplicate','wrong_session','string_flag','unknown_subtype','array_type','array_subtype')){
    Case security ("failure or incomplete response cannot succeed: $mode") {
        $e=$valid|ConvertFrom-Json;$prefix='';$suffix='';$code=0
        switch($mode){
            error_flag{$e.is_error=$true}
            error_subtype{$e.subtype='error_max_turns'}
            denial_list{$e.permission_denials=@(@{tool_name='Bash';tool_input='fake-secret'})}
            denial_event{$prefix='{"type":"system","subtype":"permission_denied"}'+"`n"}
            errors{$e|Add-Member errors @('fake-secret')}
            aborted{$e|Add-Member terminal_reason 'aborted_streaming'}
            error_event{$suffix="`n"+'{"type":"error","message":"fake-secret"}'}
            exit{$code=7}
            truncated{$suffix="`n"+'{"type":'}
            duplicate{$suffix="`n"+$valid}
            wrong_session{$prefix='{"type":"system","subtype":"init","session_id":"other"}'+"`n"}
            string_flag{$e.is_error='false'}
            unknown_subtype{$e.subtype='future'}
            array_type{$e.type=@('result')}
            array_subtype{$e.subtype=@('success')}
        }
        $body=$prefix+($e|ConvertTo-Json -Depth 12 -Compress)+$suffix
        if($mode -eq 'missing'){$body='plain output only'}
        $worker=Record;$r=Get-HarnessProviderResult $worker (Log $body) $code
        Assert-HarnessProviderResult $r $worker.provider_contract $worker.invocation_id $code
        Assert-True ($r.execution_status -eq 'failed' -and $r.usage.status -eq 'unknown' -and $null -eq $r.usage.input_tokens) 'failure accepted'
        Assert-True (-not ($r|ConvertTo-Json -Depth 12).Contains('fake-secret')) 'raw error copied'
        $r.execution_status='succeeded';$r.error_kind='none'
        Reject {Assert-HarnessProviderResult $r $worker.provider_contract $worker.invocation_id $code}
    }
}
Case unit 'last message is extracted and stale message is cleared on failure' {
    $worker=Record;$worker|Add-Member exit_code 0;$out=Join-Path $testRoot 'message.txt'
    Export-HarnessProviderLastMessage $worker (Log $valid) $out
    Assert-True (([IO.File]::ReadAllText($out)).Trim() -eq 'done') 'result missing'
    Export-HarnessProviderLastMessage $worker (Log 'truncated') $out
    Assert-True ([string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($out))) 'stale result retained'
}
Case integration 'provider change cannot reset shared token budget or attempts' {
    $root=Fixture @{execution_policy=@{max_total_tokens=120}};$worker=Record
    New-HarnessUsageReservation $root $worker
    Complete-HarnessUsageReservation $root $worker (Log $valid) 0 1
    $saved=@(Read-HarnessUsageRecords $root)[0]
    Assert-True ($saved.provider -eq 'claude' -and $saved.provider_result.usage.input_tokens -eq 100 -and $null -eq $saved.actual_cost_usd) 'ledger normalization wrong'
    Reject {New-HarnessUsageReservation $root (Record 'codex')}
    $root2=Fixture @{execution_policy=@{max_attempts_per_assignment=1}};$worker2=Record
    New-HarnessUsageReservation $root2 $worker2
    Complete-HarnessUsageReservation $root2 $worker2 (Log $valid) 0 1
    Reject {New-HarnessUsageReservation $root2 (Record 'codex')}
}
Case integration 'unknown Claude usage blocks the next Codex reservation' {
    $root=Fixture @{execution_policy=@{max_total_tokens=1000}};$worker=Record
    New-HarnessUsageReservation $root $worker;Complete-HarnessUsageReservation $root $worker (Log 'no result') 0 1
    Reject {New-HarnessUsageReservation $root (Record 'codex')}
}
Case security 'cross-provider result substitution preserves original reservation' {
    $root=Fixture;$worker=Record;New-HarnessUsageReservation $root $worker
    $worker.provider_contract.provider='codex'
    Reject {Complete-HarnessUsageReservation $root $worker (Log $valid) 0 1}
    Assert-True (@(Read-HarnessUsageRecords $root)[0].status -eq 'reserved') 'reservation lost'
}
Case integration 'native stdin and stdout preserve UTF-8 through the real worker host' {
    $root=Fixture;$fake=Join-Path $root 'native.ps1';$prompt=Join-Path $root 'prompt.txt';$log=Join-Path $root 'native.log'
    $unicode=[string][char]0xD55C+[char]0xAE00
    Write-Utf8File $prompt $unicode
    $body=@'
[Console]::InputEncoding=New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false)
$received=[Console]::In.ReadToEnd().Trim()
$expected=[string][char]0xD55C+[char]0xAE00
if($received -cne $expected){exit 9}
$event=@{type='result';subtype='success';is_error=$false;result=$received;usage=@{input_tokens=1;cache_read_input_tokens=0;cache_creation_input_tokens=0;output_tokens=1}}
[Console]::WriteLine(($event|ConvertTo-Json -Depth 6 -Compress))
exit 0
'@
    Write-Utf8File $fake $body
    $lockPath=Get-AssignmentInvokeLockPath $root 'task'
    $lease=Acquire-HarnessLock (Split-Path -Parent $lockPath) (Split-Path -Leaf $lockPath)
    try{
        $intent=New-AssignmentWorkerIntent $root 'tester' 'task' $lease (Get-HarnessPowerShellExecutable) @('-NoProfile','-ExecutionPolicy','Bypass','-File',$fake) $prompt $log $root (Record).provider_contract
        $r=Invoke-HarnessPowerShellFile (Join-Path $PSScriptRoot 'run_assignment_worker.ps1') @('-RootDir',$root,'-AssignmentId','task','-InvocationId',$intent.invocation_id) -AllowFailure
        $worker=Get-AssignmentWorkerRecord $root 'task'
        Assert-True ($r.Success -and $worker.provider_result.execution_status -eq 'succeeded') $r.Output
        Assert-True ((Get-ClaudeOutputFromLog $log 0).message -ceq $unicode) 'native Unicode corrupted'
    }finally{Release-HarnessLock $lease}
}
foreach($layout in @('standalone','nested')){
    foreach($mode in @('normal','reported_failure','missing_result')){
        Case integration ("$layout real invoke and worker completion: $mode") {
            $unicode=[string][char]0xD55C+[char]0xAE00
            $root=Join-Path $testRoot ("$layout $unicode [safe] "+[Guid]::NewGuid().ToString('N'))
            $engine=if($layout -eq 'standalone'){$root}else{Join-Path $root 'harness'}
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
            Write-Utf8File (Join-Path $engine 'reports/dispatch_packets/task.md') ("fixture prompt $unicode")
            $fake=Join-Path $root 'fake-claude.ps1'
            $body=@'
if($args -contains '--version'){'fake Claude';return}
$received=@($input) -join "`n"
$root=$env:CODEX_HARNESS_ROOT
$engine=if(Test-Path -LiteralPath (Join-Path $root 'scripts/harness_common.ps1')){$root}else{Join-Path $root 'harness'}
. (Join-Path $engine 'scripts/harness_common.ps1')
Write-Utf8File (Join-Path $engine 'reports/received.json') (@{arguments=@($args);cwd=(Get-Location).Path;prompt=$received}|ConvertTo-Json -Depth 8)
$r=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/complete_assignment.ps1') @('-Agent','tester','-AssignmentId','task','-Result','pass') -AllowFailure
if(-not $r.Success){throw $r.Output}
$global:LASTEXITCODE=0
'@
            if($mode -eq 'normal'){$body+="`n'"+$valid+"'"}
            if($mode -eq 'reported_failure'){$body+="`n'"+'{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["fake-secret"]}'+"'"}
            Write-Utf8File $fake $body
            $oldRoot=$env:CODEX_HARNESS_ROOT;$oldPath=$env:HARNESS_CLAUDE_PATH;$oldWorkspace=$env:CODEX_GIT_WORKSPACE_ROOT
            try{
                $env:CODEX_HARNESS_ROOT=$root;$env:HARNESS_CLAUDE_PATH=$fake;$env:CODEX_GIT_WORKSPACE_ROOT=$null
                if($mode -eq 'normal'){
                    $preview=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/invoke_assignment_codex.ps1') @('-Agent','tester','-AssignmentId','task','-DryRun') -AllowFailure
                    Assert-True ($preview.Success -and -not (Test-Path -LiteralPath (Join-Path $engine 'reports/received.json')) -and @(Read-HarnessUsageRecords $root).Count -eq 0) 'preview launched or reserved a worker'
                    Assert-True ([IO.File]::ReadAllText((Join-Path $engine 'reports/agent_runs/task__summary.md')).Contains('fake Claude')) 'version query used wrong provider'
                }
                $r=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/invoke_assignment_codex.ps1') @('-Agent','tester','-AssignmentId','task','-Model','fixture-model','-Ephemeral') -AllowFailure
                $worker=Get-AssignmentWorkerRecord $root 'task';$ledger=@(Read-HarnessUsageRecords $root)[0]
                Assert-True ($worker.provider_contract.provider -eq 'claude' -and $ledger.provider_result.invocation_id -eq $worker.invocation_id) 'identity lost'
                $received=[IO.File]::ReadAllText((Join-Path $engine 'reports/received.json'))|ConvertFrom-Json
                Assert-True ($received.cwd -eq (Resolve-ProjectPath $root $worker.execution_root 'workspace') -and $received.prompt.Contains($unicode) -and $received.arguments -contains '--no-session-persistence') 'cwd stdin or arguments lost'
                if($mode -eq 'normal'){
                    Assert-True ($r.Success -and $worker.status -eq 'settled' -and $ledger.usage.input_tokens -eq 100) $r.Output
                    Assert-True (([IO.File]::ReadAllText((Join-Path $engine 'reports/agent_runs/task__last_message.txt'))).Trim() -eq 'done') 'last message missing'
                }else{
                    Assert-True (-not $r.Success -and $worker.exit_code -eq 0 -and $worker.provider_result.execution_status -eq 'failed' -and $worker.status -eq 'exited') 'failed provider settled'
                    Reject {Repair-AssignmentWorkerExit $root 'tester' 'task'}
                    $recheck=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/complete_assignment.ps1') @('-Agent','tester','-AssignmentId','task','-Result','pass','-Revalidate') -AllowFailure
                    Assert-True (-not $recheck.Success) 'revalidation laundered failure'
                }
            }finally{$env:CODEX_HARNESS_ROOT=$oldRoot;$env:HARNESS_CLAUDE_PATH=$oldPath;$env:CODEX_GIT_WORKSPACE_ROOT=$oldWorkspace}
        }
    }
}
Write-Utf8File (Join-Path $testRoot 'results.json') ($results.ToArray()|ConvertTo-Json -Depth 8)
$failed=@($results|Where-Object{-not $_.passed}).Count
Write-Output "Claude results: $($results.Count-$failed)/$($results.Count) passed; artifacts: $testRoot"
if($failed){exit 1}
