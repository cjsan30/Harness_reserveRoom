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
    $root=Join-Path $testRoot ('provider [safe] '+[Guid]::NewGuid().ToString('N'))
    Write-Utf8File (Join-Path $root 'harness/project/configs/project_profile.json') ($Profile|ConvertTo-Json -Depth 10)
    return $root
}
function Record {
    return [pscustomobject]@{invocation_id=[Guid]::NewGuid().ToString('N');owner='tester';assignment_id='task';arguments=@();provider_contract=[pscustomobject]@{version=1;provider='codex';requested_model='fixture-model'}}
}
function Log([string]$Root,[string]$Body){$path=Join-Path $Root 'events.log';Write-Utf8File $path $Body;return $path}
$valid='{"type":"turn.started"}'+"`n"+'{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20}}'
Case unit 'legacy profile and worker retain Codex identity without inferred billing' {
    $root=Fixture
    Assert-True ((Get-HarnessConfiguredProvider $root) -eq 'codex') 'wrong legacy provider'
    $contract=Get-HarnessWorkerProviderContract ([pscustomobject]@{arguments=@('exec','-m','old-model')})
    Assert-True ($contract.provider -eq 'codex' -and $contract.requested_model -eq 'old-model') 'legacy model lost'
}
Case unit 'adapter builds the existing restricted Codex arguments' {
    $root=Fixture;$fake=Join-Path $root 'fake.ps1';Write-Utf8File $fake 'throw "must not execute during planning"'
    $old=$env:HARNESS_CODEX_PATH
    try{$env:HARNESS_CODEX_PATH=$fake;$p=New-HarnessProviderLaunch 'codex' $root (Join-Path $root 'message.txt') 'fixture-model' -Ephemeral
        Assert-True ($p.executable -eq $fake -and $p.arguments[0] -eq 'exec' -and $p.arguments -contains 'workspace-write' -and $p.arguments -contains '--json' -and $p.arguments -contains '--ephemeral' -and $p.arguments -notcontains '--dangerously-bypass-approvals-and-sandbox' -and $p.input_mode -eq 'stdin') 'wrong launch contract'
        $blank=New-HarnessProviderLaunch 'codex' $root (Join-Path $root 'message.txt') '   '
        Assert-True ($null -eq $blank.contract.requested_model -and $blank.arguments -notcontains '-m') 'blank model was recorded as requested'
    }finally{$env:HARNESS_CODEX_PATH=$old}
}
foreach($selection in @(@{version=1;name='unsupported'},@{version=99;name='codex'},@{version='1';name='codex'},@{version=1;name='codex';adapter='evil.ps1'},$null)){
    Case security ('unsupported selection rejected: '+($selection|ConvertTo-Json -Compress)) {
        $root=Fixture @{worker_provider=$selection}
        Reject {Get-HarnessConfiguredProvider $root}
        Assert-True (@(Read-HarnessUsageRecords $root).Count -eq 0) 'rejected provider consumed reservation'
    }
}
Case security 'missing explicit executable cannot fall back to installed Codex' {
    $old=$env:HARNESS_CODEX_PATH
    try{$env:HARNESS_CODEX_PATH=Join-Path $testRoot 'nonexistent.exe';Reject {New-HarnessProviderLaunch 'codex' $testRoot 'out.txt' ''}}finally{$env:HARNESS_CODEX_PATH=$old}
}
foreach($mode in @('completed','plain','provider_error','process_exit')){
    Case unit ("normalized result separates process response and usage: $mode") {
        $root=Fixture;$worker=Record;$body=$valid;$code=0
        if($mode -eq 'plain'){$body='plain output'}
        if($mode -eq 'provider_error'){$body=$valid+"`n"+'{"type":"error","message":"fake-secret-never-copy"}'}
        if($mode -eq 'process_exit'){$code=7}
        $result=Get-HarnessProviderResult $worker (Log $root $body) $code
        Assert-HarnessProviderResult $result $worker.provider_contract $worker.invocation_id $code
        if($mode -eq 'completed'){Assert-True ($result.execution_status -eq 'succeeded' -and $result.response_status -eq 'completed' -and $result.usage.input_tokens -eq 100) 'complete result wrong'}
        if($mode -eq 'plain'){Assert-True ($result.execution_status -eq 'succeeded' -and $result.response_status -eq 'unknown' -and $null -eq $result.usage.input_tokens) 'unknown was inferred'}
        if($mode -in @('provider_error','process_exit')){Assert-True ($result.execution_status -eq 'failed' -and $result.usage.status -eq 'unknown') 'failure accepted'}
        Assert-True (-not ($result|ConvertTo-Json -Depth 8).Contains('fake-secret-never-copy') -and $null -eq $result.resolved_model) 'raw error or inferred model leaked'
    }
}
foreach($field in @('version','provider','invocation_id','requested_model','exit_code')){
    Case security ("mismatched result rejected: $field") {
        $root=Fixture;$worker=Record;$result=Get-HarnessProviderResult $worker (Log $root $valid) 0
        switch($field){version{$result.version=2} provider{$result.provider='claude'} invocation_id{$result.invocation_id=[Guid]::NewGuid().ToString('N')} requested_model{$result.requested_model='other'} exit_code{$result.exit_code=7}}
        Reject {Assert-HarnessProviderResult $result $worker.provider_contract $worker.invocation_id 0}
    }
}
Case integration 'reservation binds provider and model and refuses replacement result' {
    $root=Fixture;$worker=Record;New-HarnessUsageReservation $root $worker
    $worker.provider_contract.requested_model='changed'
    Reject {Complete-HarnessUsageReservation $root $worker (Log $root $valid) 0 1}
    Assert-True (@(Read-HarnessUsageRecords $root)[0].status -eq 'reserved') 'mismatch refunded reservation'
}
Case integration 'normalized result persists in ledger and unknown usage blocks budget' {
    $root=Fixture @{execution_policy=@{max_total_tokens=100}};$worker=Record
    New-HarnessUsageReservation $root $worker
    Complete-HarnessUsageReservation $root $worker (Log $root 'plain output') 0 1
    $saved=@(Read-HarnessUsageRecords $root)[0]
    Assert-True ($saved.provider_result.response_status -eq 'unknown' -and $null -eq $saved.actual_cost_usd) 'missing normalized result'
    Reject {New-HarnessUsageReservation $root (Record)}
}
Case security 'ledger result cannot disagree with charged usage' {
    $root=Fixture;$worker=Record;New-HarnessUsageReservation $root $worker
    Complete-HarnessUsageReservation $root $worker (Log $root $valid) 0 1
    $saved=@(Read-HarnessUsageRecords $root)[0];$saved.usage.input_tokens=999
    Write-Utf8File (Join-Path (Get-HarnessUsageDirectory $root) ($worker.invocation_id+'.json')) ($saved|ConvertTo-Json -Depth 10)
    Reject {Read-HarnessUsageRecords $root}
}
foreach($mode in @('normal','reported_failure')){
    Case integration ("real worker host and completion proof: $mode") {
        $root=Fixture ([IO.File]::ReadAllText((Join-Path $source 'configs/project_profile.template.json'))|ConvertFrom-Json)
        foreach($dir in @('scripts','configs')){Copy-Item -LiteralPath (Join-Path $source $dir) -Destination (Join-Path $root ('harness/'+$dir)) -Recurse}
        Invoke-HarnessProcess git @('init','-b','main',$root)|Out-Null
        Write-Utf8File (Join-Path $root 'baseline.txt') 'fixture'
        Invoke-HarnessProcess git @('-C',$root,'add','baseline.txt')|Out-Null
        Invoke-HarnessProcess git @('-C',$root,'-c','core.hooksPath=','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-m','fixture')|Out-Null
        $dirs=Get-AssignmentDirectories $root 'tester'
        Write-Utf8File (Join-Path $dirs.Inbox 'task.md') "- assignment_id: task`n- status: inbox`n- result: pending`n- validation: git cat-file -e HEAD:baseline.txt`n"
        Write-Utf8File (Join-Path $root 'harness/reports/dispatch_packets/task.md') 'isolated provider test'
        $fake=Join-Path $root 'fake-provider.ps1'
        $body=@'
if($args -contains '--version'){'fake provider';return}
. (Join-Path $env:CODEX_HARNESS_ROOT 'harness/scripts/harness_common.ps1')
$r=Invoke-HarnessPowerShellFile (Join-Path $env:CODEX_HARNESS_ROOT 'harness/scripts/complete_assignment.ps1') @('-Agent','tester','-AssignmentId','task','-Result','pass') -AllowFailure
if(-not $r.Success){throw $r.Output}
'{"type":"turn.started"}'
'{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20}}'
$global:LASTEXITCODE=0
'@
        if($mode -eq 'reported_failure'){$body+="`n"+"'{`"type`":`"turn.failed`"}'"}
        Write-Utf8File $fake $body
        $oldRoot=$env:CODEX_HARNESS_ROOT;$oldPath=$env:HARNESS_CODEX_PATH;$oldWorkspace=$env:CODEX_GIT_WORKSPACE_ROOT
        try{
            $env:CODEX_HARNESS_ROOT=$root;$env:HARNESS_CODEX_PATH=$fake;$env:CODEX_GIT_WORKSPACE_ROOT=$null
            $r=Invoke-HarnessPowerShellFile (Join-Path $PSScriptRoot 'invoke_assignment_codex.ps1') @('-Agent','tester','-AssignmentId','task','-Model','fixture-model') -AllowFailure
            $worker=Get-AssignmentWorkerRecord $root 'task';$ledger=@(Read-HarnessUsageRecords $root)[0]
            Assert-True ($worker.provider_contract.requested_model -eq 'fixture-model' -and $ledger.provider_result.invocation_id -eq $worker.invocation_id) 'provider identity lost across host'
            if($mode -eq 'normal'){Assert-True ($r.Success -and $worker.status -eq 'settled' -and $ledger.usage.input_tokens -eq 100) $r.Output}
            else{
                Assert-True (-not $r.Success -and $worker.exit_code -eq 0 -and $worker.provider_result.execution_status -eq 'failed' -and $worker.status -eq 'exited') 'provider failure was accepted'
                Reject {Assert-AssignmentCompletionEvidence $root 'tester' 'task' ([IO.File]::ReadAllText((Join-Path $dirs.Done 'task__pass.md')))}
                Reject {Repair-AssignmentWorkerExit $root 'tester' 'task'}
            }
        }finally{$env:CODEX_HARNESS_ROOT=$oldRoot;$env:HARNESS_CODEX_PATH=$oldPath;$env:CODEX_GIT_WORKSPACE_ROOT=$oldWorkspace}
    }
}
Case integration 'worker exceeding max_invocation_seconds is stopped and recorded as a failed exit' {
    $profile=[IO.File]::ReadAllText((Join-Path $source 'configs/project_profile.template.json'))|ConvertFrom-Json
    $profile.execution_policy.max_invocation_seconds=3
    $root=Fixture $profile
    foreach($dir in @('scripts','configs')){Copy-Item -LiteralPath (Join-Path $source $dir) -Destination (Join-Path $root ('harness/'+$dir)) -Recurse}
    Invoke-HarnessProcess git @('init','-b','main',$root)|Out-Null
    Write-Utf8File (Join-Path $root 'baseline.txt') 'fixture'
    Invoke-HarnessProcess git @('-C',$root,'add','baseline.txt')|Out-Null
    Invoke-HarnessProcess git @('-C',$root,'-c','core.hooksPath=','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-m','fixture')|Out-Null
    $dirs=Get-AssignmentDirectories $root 'tester'
    Write-Utf8File (Join-Path $dirs.Inbox 'task.md') "- assignment_id: task`n- status: inbox`n- result: pending`n- validation: git cat-file -e HEAD:baseline.txt`n"
    Write-Utf8File (Join-Path $root 'harness/reports/dispatch_packets/task.md') 'isolated provider test'
    $childPidFile=Join-Path $root 'child.pid'
    $fake=Join-Path $root 'fake-provider.ps1'
    # The fake provider is a script run inside the worker host; the hung work is a real
    # child process, like the node process behind the Codex CLI.
    Write-Utf8File $fake (@'
if($args -contains '--version'){'fake provider';return}
. (Join-Path $env:CODEX_HARNESS_ROOT 'harness/scripts/harness_common.ps1')
'OPENAI_API_KEY=sk-fixtureTimeoutSecret1234567890'
'{"type":"turn.started"}'
$info=New-Object Diagnostics.ProcessStartInfo
$info.FileName=Get-HarnessPowerShellExecutable;$info.Arguments='-NoProfile -Command "Start-Sleep -Seconds 60"'
$info.WorkingDirectory=[IO.Path]::GetTempPath();$info.UseShellExecute=$false;$info.CreateNoWindow=$true
$child=[Diagnostics.Process]::Start($info)
[IO.File]::WriteAllText('__CHILD_PID__',[string]$child.Id)
$child.WaitForExit()
$global:LASTEXITCODE=0
'@).Replace('__CHILD_PID__',$childPidFile)
    $oldRoot=$env:CODEX_HARNESS_ROOT;$oldPath=$env:HARNESS_CODEX_PATH;$oldWorkspace=$env:CODEX_GIT_WORKSPACE_ROOT
    try{
        $env:CODEX_HARNESS_ROOT=$root;$env:HARNESS_CODEX_PATH=$fake;$env:CODEX_GIT_WORKSPACE_ROOT=$null
        $timer=[Diagnostics.Stopwatch]::StartNew()
        $r=Invoke-HarnessPowerShellFile (Join-Path $PSScriptRoot 'invoke_assignment_codex.ps1') @('-Agent','tester','-AssignmentId','task','-Model','fixture-model') -AllowFailure
        $timer.Stop()
        $worker=Get-AssignmentWorkerRecord $root 'task';$ledger=@(Read-HarnessUsageRecords $root)[0]
        Assert-True ($timer.Elapsed.TotalSeconds -lt 45) "timeout did not stop the worker: $($timer.Elapsed.TotalSeconds)s"
        Assert-True ($worker.timeout_seconds -eq 3 -and $worker.timed_out -eq $true -and $worker.exit_code -eq 124) "timeout not recorded: $($worker|ConvertTo-Json -Depth 4)"
        Assert-True ($worker.provider_result.execution_status -eq 'failed' -and $worker.provider_result.error_kind -eq 'process_exit') 'timed out run was not a failed provider result'
        Assert-True ($ledger.status -eq 'completed' -and $ledger.usage.status -eq 'unknown' -and $null -eq $ledger.usage.input_tokens) 'timed out usage was not unknown'
        Assert-True ([IO.File]::ReadAllText((Resolve-ProjectPath $root $worker.log_file 'log')).Contains('exceeded max_invocation_seconds=3')) 'timeout not written to the worker log'
        Assert-True (-not [IO.File]::ReadAllText((Resolve-ProjectPath $root $worker.log_file 'log')).Contains('fixtureTimeoutSecret')) 'provider output secret reached the worker log'
        $childPid=[int][IO.File]::ReadAllText($childPidFile)
        Assert-True ($null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) 'hung provider child process survived'
        Assert-True (-not $r.Success) 'timed out assignment reported success'
    }finally{$env:CODEX_HARNESS_ROOT=$oldRoot;$env:HARNESS_CODEX_PATH=$oldPath;$env:CODEX_GIT_WORKSPACE_ROOT=$oldWorkspace}
}
Case unit 'max_invocation_seconds accepts null or a positive integer only' {
    foreach($bad in @(0,-1,'30',1.5)){
        $profile=[IO.File]::ReadAllText((Join-Path $source 'configs/project_profile.template.json'))|ConvertFrom-Json
        $profile.execution_policy.max_invocation_seconds=$bad
        $root=Fixture $profile
        Reject {Get-HarnessExecutionPolicy $root}
    }
    $profile=[IO.File]::ReadAllText((Join-Path $source 'configs/project_profile.template.json'))|ConvertFrom-Json
    $profile.execution_policy.max_invocation_seconds=600
    Assert-True ((Get-HarnessExecutionPolicy (Fixture $profile)).max_invocation_seconds -eq 600) 'valid limit rejected'
}
Write-Utf8File (Join-Path $testRoot 'results.json') ($results.ToArray()|ConvertTo-Json -Depth 8)
$failed=@($results|Where-Object{-not $_.passed}).Count
Write-Output "Provider results: $($results.Count-$failed)/$($results.Count) passed; artifacts: $testRoot"
if($failed){exit 1}
