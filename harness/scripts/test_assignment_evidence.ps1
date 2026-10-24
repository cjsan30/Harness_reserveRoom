param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$engine=Split-Path -Parent $PSScriptRoot
if(-not $OutputDirectory){$OutputDirectory=Join-Path $engine '.test-output'}
$testRoot=Join-Path $OutputDirectory ([Guid]::NewGuid().ToString('N'))
Ensure-HarnessDirectory $testRoot
$results=New-Object 'System.Collections.Generic.List[object]'
function Assert-True($Value,[string]$Message){if(-not $Value){throw $Message}}
function Assert-Rejected([scriptblock]$Body){$rejected=$false;try{& $Body|Out-Null}catch{$rejected=$true};Assert-True $rejected 'operation should be rejected'}
function Test-Case([string]$Name,[scriptblock]$Body){try{& $Body;$results.Add(@{name=$Name;passed=$true});Write-Output "PASS $Name"}catch{$results.Add(@{name=$Name;passed=$false;error=$_.Exception.Message});Write-Output "FAIL $Name : $($_.Exception.Message)"}}
function New-Fixture([string]$Validator='$ErrorActionPreference="Stop"; if ((Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "source.txt")).Trim() -ne "expected") { exit 7 }; Write-Output "fixture assertion passed"'){
    $root=Join-Path $testRoot ('target [safe] '+[Guid]::NewGuid().ToString('N'))
    Write-Utf8File (Join-Path $root 'harness/project/configs/project_profile.json') '{}'
    Write-Utf8File (Join-Path $root 'source.txt') 'expected'
    Write-Utf8File (Join-Path $root 'validate.ps1') $Validator
    Invoke-HarnessProcess git @('init','-b','main',$root)|Out-Null
    Invoke-HarnessProcess git @('-C',$root,'add','source.txt','validate.ps1')|Out-Null
    Invoke-HarnessProcess git @('-C',$root,'-c','core.hooksPath=','-c','user.name=Fixture','-c','user.email=test@example.invalid','commit','-m','fixture')|Out-Null
    $dirs=Get-AssignmentDirectories $root 'tester'
    Write-Utf8File (Join-Path $dirs.InProgress 'task.md') "- assignment_id: task`n- status: in_progress`n- result: pending`n- validation: pwsh -NoProfile -ExecutionPolicy Bypass -File validate.ps1`n"
    return $root
}
function Complete([string]$Root,[string]$Result='pass',[switch]$Revalidate){
    $old=$env:CODEX_HARNESS_ROOT
    try{$env:CODEX_HARNESS_ROOT=$Root;$arguments=@('-Agent','tester','-AssignmentId','task','-Result',$Result);if($Revalidate){$arguments+='-Revalidate'};return Invoke-HarnessPowerShellFile (Join-Path $PSScriptRoot 'complete_assignment.ps1') $arguments -AllowFailure}
    finally{$env:CODEX_HARNESS_ROOT=$old}
}
function DoneText([string]$Root){return [IO.File]::ReadAllText((Join-Path (Get-AssignmentDirectories $Root 'tester').Done 'task__pass.md'))}
function Assert-Pass([string]$Root){$r=Complete $Root;Assert-True $r.Success $r.Output;return Assert-AssignmentCompletionEvidence $Root 'tester' 'task' (DoneText $Root)}
Test-Case 'success executes assertion and binds code command log and time' {
    $root=New-Fixture;$e=Assert-Pass $root
    Assert-True ($e.exit_code -eq 0 -and $e.before.head -match '^[a-f0-9]{40,64}$' -and $e.duration_seconds -ge 0 -and $e.log_sha256.Length -eq 64) 'evidence metadata missing'
    Assert-True ([IO.File]::ReadAllText((Join-Path $root $e.log)).Contains('fixture assertion passed')) 'command did not execute'
    $r=Complete $root;Assert-True $r.Success 'valid completion is not idempotent'
}
Test-Case 'nonzero command exit leaves assignment incomplete with failure evidence' {
    $root=New-Fixture 'Write-Output "fixture assertion failed"; exit 7'
    $r=Complete $root;Assert-True (-not $r.Success) 'failed assertion accepted'
    $records=@(Get-ChildItem -LiteralPath (Get-AssignmentEvidenceDirectory $root) -Filter '*.json')
    $e=[IO.File]::ReadAllText($records[0].FullName)|ConvertFrom-Json
    Assert-True ($e.status -eq 'fail' -and $e.exit_code -eq 7) 'failure evidence missing'
    Assert-True (Test-Path -LiteralPath (Join-Path (Get-AssignmentDirectories $root 'tester').InProgress 'task.md')) 'failure lost assignment'
}
Test-Case 'validation that edits source cannot certify its old snapshot' {
    $root=New-Fixture 'Add-Content -LiteralPath (Join-Path $PSScriptRoot "source.txt") -Value changed; exit 0'
    Assert-True (-not (Complete $root).Success) 'source mutation accepted'
}
Test-Case 'PowerShell validation errors cannot be hidden by a trailing exit zero' {
    $root=New-Fixture 'Get-Content -LiteralPath nonexistent-required-input; exit 0'
    Assert-True (-not (Complete $root).Success) 'PowerShell command error masked'
}
foreach($command in @('', 'echo pass','git --version','test-command || true')){
    Test-Case ('empty weak or masked validation rejected: '+$command) {
        Assert-Rejected {Get-AssignmentValidationCommand ("- validation: "+$command)}
    }
}
Test-Case 'duplicate validation metadata rejected' {Assert-Rejected {Get-AssignmentValidationCommand "- validation: first`n- validation: second"}}
Test-Case 'ambiguous assignment state cannot move to done' {
    $root=New-Fixture;$path=Join-Path (Get-AssignmentDirectories $root 'tester').InProgress 'task.md'
    Append-Utf8File $path "`n- result: pass`n"
    Assert-True (-not (Complete $root).Success) 'ambiguous assignment accepted'
    Assert-True (Test-Path -LiteralPath $path) 'ambiguous assignment moved'
}
Test-Case 'manually written legacy pass is unverified' {
    $root=New-Fixture
    Assert-Rejected {Assert-AssignmentCompletionEvidence $root 'tester' 'task' "- result: pass`n"}
}
foreach($change in @('tracked','untracked','index','branch','head','log','missing_log','assignment','owner','identity','version')){
    Test-Case ("completion refuses changed $change") {
        $root=New-Fixture;$e=Assert-Pass $root;$content=DoneText $root
        switch($change){
            'tracked' {Write-Utf8File (Join-Path $root 'source.txt') 'changed'}
            'untracked' {Write-Utf8File (Join-Path $root 'new-source.txt') 'new'}
            'index' {Invoke-HarnessProcess git @('-C',$root,'add','harness/project/configs/project_profile.json')|Out-Null}
            'branch' {Invoke-HarnessProcess git @('-C',$root,'switch','-c','different')|Out-Null}
            'head' {Invoke-HarnessProcess git @('-C',$root,'-c','core.hooksPath=','-c','user.name=Fixture','-c','user.email=test@example.invalid','commit','--allow-empty','-m','new head')|Out-Null}
            'log' {Write-Utf8File (Join-Path $root $e.log) 'changed'}
            'missing_log' {[IO.File]::Move((Join-Path $root $e.log),(Join-Path $root ($e.log+'.removed')))}
            'assignment' {$content += "`n- task: altered`n"}
            'owner' {$e.owner='other'}
            'identity' {$e.assignment_id='other'}
            'version' {$e.version=99}
        }
        if($change -in @('owner','identity','version')){Write-Utf8File (Join-Path (Get-AssignmentEvidenceDirectory $root) ($e.id+'.json')) ($e|ConvertTo-Json -Depth 10)}
        Assert-Rejected {Assert-AssignmentCompletionEvidence $root 'tester' 'task' $content}
    }
}
Test-Case 'worker nonzero exit, active exit and another attempt invalidate success' {
    $root=New-Fixture;$e=Assert-Pass $root
    $lease=Acquire-HarnessLock (Get-HarnessLockRoot $root) 'invoke_task'
    try{$worker=New-AssignmentWorkerIntent $root 'tester' 'task' $lease 'unused' @() '' '' $root}finally{Release-HarnessLock $lease}
    Assert-Rejected {Assert-AssignmentCompletionEvidence $root 'tester' 'task' (DoneText $root)}
    $e.invocation_id=$worker.invocation_id
    Write-Utf8File (Join-Path (Get-AssignmentEvidenceDirectory $root) ($e.id+'.json')) ($e|ConvertTo-Json -Depth 10)
    Assert-Rejected {Assert-AssignmentCompletionEvidence $root 'tester' 'task' (DoneText $root)}
    $worker.status='exited';$worker.exit_code=9
    Write-Utf8File (Get-AssignmentWorkerPaths $root 'task').Record ($worker|ConvertTo-Json -Depth 8)
    Assert-Rejected {Assert-AssignmentCompletionEvidence $root 'tester' 'task' (DoneText $root)}
    Assert-Rejected {Repair-AssignmentWorkerExit $root 'tester' 'task'}
    $worker.status='unknown';$worker.exit_code=0
    Write-Utf8File (Get-AssignmentWorkerPaths $root 'task').Record ($worker|ConvertTo-Json -Depth 8)
    Assert-Rejected {Assert-AssignmentCompletionEvidence $root 'tester' 'task' (DoneText $root)}
}
Test-Case 'explicit revalidation replaces stale evidence and preserves audit history' {
    $root=New-Fixture;$old=Assert-Pass $root
    Write-Utf8File (Join-Path $root 'extra-source.txt') 'new source'
    Assert-True (-not (Complete $root).Success) 'idempotent call accepted stale evidence'
    $r=Complete $root -Revalidate;Assert-True $r.Success $r.Output
    $fresh=Assert-AssignmentCompletionEvidence $root 'tester' 'task' (DoneText $root)
    Assert-True ($fresh.id -ne $old.id -and (Test-Path -LiteralPath (Join-Path (Get-AssignmentEvidenceDirectory $root) ($old.id+'.json')))) 'audit history replaced'
}
Test-Case 'UTF-8 source filenames are included in the snapshot' {
    $root=New-Fixture
    $name=[string][char]0xD55C+[char]0xAE00+'.txt'
    Write-Utf8File (Join-Path $root $name) 'before'
    $e=Assert-Pass $root
    Write-Utf8File (Join-Path $root $name) 'after'
    Assert-Rejected {Assert-AssignmentCompletionEvidence $root 'tester' 'task' (DoneText $root)}
}
Test-Case 'seed resume never trusts a legacy pass file' {
    $root=New-Fixture;$dirs=Get-AssignmentDirectories $root 'tester'
    [IO.File]::Move((Join-Path $dirs.InProgress 'task.md'),(Join-Path $dirs.Done 'task__pass.md'))
    Write-Utf8File (Join-Path $dirs.Done 'task__pass.md') "- assignment_id: task`n- status: done`n- result: pass`n- source_plan_id: evidence-plan`n- seed_task_key: tester|sample`n"
    Write-Utf8File (Join-Path $root 'plan.md') "- plan_id: evidence-plan`n`n## Assignment`n- owner: tester`n- title: sample`n`n### Task`nCheck evidence.`n"
    $old=$env:CODEX_HARNESS_ROOT
    try {
        $env:CODEX_HARNESS_ROOT=$root
        $r=Invoke-HarnessPowerShellFile (Join-Path $PSScriptRoot 'get_seed_handoff_resume.ps1') @('-PlanFile','plan.md','-Json') -AllowFailure
        Assert-True $r.Success $r.Output
        $report=$r.Output|ConvertFrom-Json
        Assert-True ($report.status -eq 'needs_recovery' -and $report.counts.passed -eq 0 -and $r.Output.Contains('validation_unverified')) 'legacy pass accepted by resume'
    }finally{$env:CODEX_HARNESS_ROOT=$old}
}
# Load the production functions without running dispatch's orchestration entry point.
$dispatchAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'dispatch_seed_plan.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Get-AssignmentLifecycleRecord','Finalize-FeatureBranchForSeedAssignment')){
    $definition=$dispatchAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
Test-Case 'dispatch lifecycle rejects a pass after source changes' {
    $rootDir=New-Fixture;$null=Assert-Pass $rootDir
    Assert-True ((Get-AssignmentLifecycleRecord 'tester' 'task').Result -eq 'pass') 'verified pass not recognized'
    Write-Utf8File (Join-Path $rootDir 'source.txt') 'changed'
    Assert-Rejected {Get-AssignmentLifecycleRecord 'tester' 'task'}
}
Test-Case 'feature finalization rejects missing proof before touching Git' {
    $rootDir=New-Fixture;$dirs=Get-AssignmentDirectories $rootDir 'tester'
    Write-Utf8File (Join-Path $dirs.Done 'task__pass.md') "- assignment_id: task`n- status: done`n- result: pass`n"
    $before=Get-AssignmentCodeSnapshot $rootDir $rootDir
    $rejection=''
    try {Finalize-FeatureBranchForSeedAssignment 'tester' 'task' 'tester/task'|Out-Null} catch {$rejection=$_.Exception.Message}
    Assert-True ($rejection -like '*no unique execution evidence*') 'finalization did not fail at the evidence guard'
    Assert-True (Test-AssignmentSnapshotEqual $before (Get-AssignmentCodeSnapshot $rootDir $rootDir)) 'finalization changed source or index'
}
Write-Utf8File (Join-Path $testRoot 'results.json') ($results.ToArray()|ConvertTo-Json -Depth 5)
$failed=@($results|Where-Object{-not $_.passed}).Count
Write-Output "Evidence results: $($results.Count-$failed)/$($results.Count) passed; artifacts: $testRoot"
if($failed){exit 1}
