param([string]$Root='')
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'harness_common.ps1')
if(-not $Root){$Root=Get-HarnessRoot $PSScriptRoot}
$Root=[IO.Path]::GetFullPath($Root)
$env:CODEX_HARNESS_ROOT=$Root
$env:CODEX_GIT_WORKSPACE_ROOT=$null
$env:GIT_OPTIONAL_LOCKS='0'
$alerts=New-Object 'System.Collections.Generic.List[object]'
$observed=New-Object 'System.Collections.Generic.Dictionary[string,string]'
$directories=@{}
$script:DashboardReadBytes=0
$script:DashboardEntryCount=0
function Add-DashboardAlert($Code,$Message,$Action){$alerts.Add([pscustomobject]@{code=$Code;message=$Message;action=$Action})}
function Get-DashboardText($Value){
    $text=([string]$Value -replace '[\x00-\x1f]',' ').Trim()
    $text=$text -replace '(?i)(?:sk-[a-z0-9_-]{12,}|gh[pousr]_[a-z0-9]{12,}|Bearer\s+\S+)','[redacted]'
    if($text.Length -gt 240){$text=$text.Substring(0,240)+'...'}
    return $text
}
function Assert-DashboardPath([string]$Path){
    $full=Resolve-ProjectPath $Root $Path 'dashboard path' -AllowProjectRoot
    $cursor=$full
    while($cursor -and $cursor.Length -ge $Root.TrimEnd('\','/').Length){
        if(Test-Path -LiteralPath $cursor){
            $item=Get-Item -Force -LiteralPath $cursor
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'linked dashboard paths are refused'}
        }
        if([string]::Equals($cursor,$Root,(Get-HarnessPathComparison))){break}
        $cursor=Split-Path -Parent $cursor
    }
    return $full
}
function Read-DashboardFile([string]$Path){
    $safe=Assert-DashboardPath $Path
    $item=Get-Item -LiteralPath $safe
    if($item.PSIsContainer -or $item.Length -gt 2097152){throw 'dashboard input exceeds read limit'}
    $script:DashboardReadBytes+=$item.Length
    if($script:DashboardReadBytes -gt 33554432){throw 'dashboard aggregate read limit exceeded'}
    $observed[$safe]=[string]$item.Length+':'+[string]$item.LastWriteTimeUtc.Ticks
    return [IO.File]::ReadAllText($safe)
}
function Get-DashboardFiles([string]$Path,[string]$Filter='*'){
    $safe=Assert-DashboardPath $Path
    if(Test-Path -LiteralPath $safe){
        $items=@(Get-ChildItem -LiteralPath $safe -Force -Filter $Filter)
        if($items.Count -gt 2000){throw 'dashboard directory exceeds item limit'}
        $script:DashboardEntryCount+=$items.Count
        if($script:DashboardEntryCount -gt 5000){throw 'dashboard aggregate item limit exceeded'}
        # Observe the directory too, so atomic replacement / concurrent queue moves
        # are reported as a non-transactional snapshot instead of silent success.
        $directories[$safe]=@{filter=$Filter;fingerprint=(@($items|Sort-Object Name|ForEach-Object{$_.Name+':'+$_.LastWriteTimeUtc.Ticks}) -join '|')}
        foreach($item in $items){$null=Assert-DashboardPath $item.FullName;$item}
    }
}
function Get-DashboardFields([string]$Text){
    $fields=@{}
    foreach($line in ($Text -split '\r?\n')){
        if($line -match '^\s*- ([a-z_]+):\s*(.*)$'){
            $key=$Matches[1]
            if($fields.ContainsKey($key)){throw 'duplicate metadata field'}
            $fields[$key]=$Matches[2].Trim()
        }
    }
    return $fields
}
function Get-DashboardWorker($Record){
    $status='unconfirmed'
    if($Record.status -cin @('exited','settled')){$status='exited'}
    elseif($Record.status -ceq 'running' -and $Record.host -ceq [Environment]::MachineName){
        try{
            $process=Get-Process -Id ([int]$Record.worker_pid) -ErrorAction Stop
            # PS7 decodes ISO JSON timestamps to DateTime; PS5 keeps strings.
            # Parsing a DateTime through its culture-formatted string loses UTC.
            $expected=if($Record.worker_started_at -is [DateTime]){$Record.worker_started_at.ToUniversalTime()}else{([DateTimeOffset]::Parse($Record.worker_started_at)).UtcDateTime}
            if($Record.PSObject.Properties['worker_process_identity']){
                $observedIdentity=Get-HarnessLinuxProcessIdentity ([int]$Record.worker_pid)
                if($observedIdentity -and $Record.worker_process_identity -ceq $observedIdentity){$status='running'}
            }elseif([Math]::Abs(($process.StartTime.ToUniversalTime()-$expected).TotalMilliseconds) -lt 10){$status='running'}
            if($status -eq 'running'){$expected=$process.StartTime.ToUniversalTime()}
        }catch{}
    }
    $elapsed=if($status -eq 'running'){[Math]::Max(0,[Math]::Floor(([DateTime]::UtcNow-$expected).TotalSeconds))}else{$null}
    return [pscustomobject]@{assignment_id=(Get-DashboardText $Record.assignment_id);owner=(Get-DashboardText $Record.owner);invocation_id=$Record.invocation_id;status=$status;record_status=$Record.status;provider=(Get-HarnessWorkerProviderContract $Record).provider;started_at=$Record.worker_started_at;elapsed_seconds=$elapsed;exit_code=$Record.exit_code;observed_at=[DateTime]::UtcNow.ToString('o')}
}
$now=[DateTime]::UtcNow.ToString('o')
$snapshot=[ordered]@{schema_version=1;generated_at=$now;collection_status='ok';scope='all_retained_assignments';project=$null;tasks=@();workers=@();usage=$null;validation=$null;approvals=@();alerts=@();summary=$null}
try{
    $null=Assert-DashboardPath $Root
    $engine=Get-HarnessEngineRoot $Root
    $null=Assert-DashboardPath $engine
    $profilePath=Get-ProjectProfilePath $Root
    $profile=$null;$configured=(-not [string]::IsNullOrWhiteSpace($profilePath))
    if($configured){$profile=(Read-DashboardFile $profilePath)|ConvertFrom-Json}
    $branch=$null;$head=$null
    try{$branch=(Invoke-AssignmentSnapshotGit $Root 'branch').Trim();$head=(Invoke-AssignmentSnapshotGit $Root 'head').Trim()}catch{}
    $snapshot.project=[pscustomobject]@{name=$(if($configured){Get-DashboardText $profile.project.name}else{Split-Path -Leaf $Root});root=$Root;configured=$configured;branch=$branch;head=$head}
    if(-not $configured){Add-DashboardAlert 'profile_missing' '활성 프로젝트 프로필이 없습니다.' '대상 프로젝트에 어댑터를 초기화하세요. 이 화면은 실행을 시작하지 않습니다.'}
    $workers=@{};$workerRows=New-Object 'System.Collections.Generic.List[object]'
    $locks=Get-HarnessLockRoot $Root
    foreach($directory in @(Get-DashboardFiles $locks 'invoke_*')){
        if(-not $directory.PSIsContainer){continue}
        $recordPath=Join-Path $directory.FullName 'worker.json'
        if(-not (Test-Path -LiteralPath $recordPath)){continue}
        try{
            $null=Read-DashboardFile $recordPath
            $id=$directory.Name.Substring(7)
            $record=Get-AssignmentWorkerRecord $Root $id
            $row=Get-DashboardWorker $record
            $workers[$id]=$record;$workerRows.Add($row)
            if($row.status -eq 'unconfirmed'){Add-DashboardAlert 'worker_unconfirmed' ('실행 상태 확인 필요: '+(Get-DashboardText $id)) '프로세스와 복구 기록을 확인하세요. 자동 재시도하지 않습니다.'}
        }catch{Add-DashboardAlert 'worker_invalid' '읽을 수 없는 worker 기록이 있습니다.' '로컬 worker 기록을 점검하세요.'}
    }
    $snapshot.workers=@($workerRows.ToArray())
    $queueRoot=Get-HarnessConfiguredPath $Root 'assignments_root' 'harness/assignments'
    $taskRows=New-Object 'System.Collections.Generic.List[object]'
    foreach($owner in @(Get-DashboardFiles $queueRoot)){
        if(-not $owner.PSIsContainer -or $owner.Name.StartsWith('.')){continue}
        $pending=$false
        foreach($journal in @(Get-DashboardFiles (Join-Path $owner.FullName '.transitions') '*.json')){
            try{if(((Read-DashboardFile $journal.FullName)|ConvertFrom-Json).status -cne 'committed'){$pending=$true}}catch{$pending=$true}
        }
        if($pending){Add-DashboardAlert 'queue_unresolved' ('큐 전환 확인 필요: '+(Get-DashboardText $owner.Name)) 'repair_assignment_state의 복구 절차를 확인하세요.'}
        foreach($bucket in @('inbox','in_progress','done')){
            foreach($file in @(Get-DashboardFiles (Join-Path $owner.FullName $bucket) '*.md')){
                if($file.PSIsContainer){continue}
                try{
                    $content=Read-DashboardFile $file.FullName;$meta=Get-DashboardFields $content
                    $null=Assert-SafePathToken $meta.assignment_id 'assignment id'
                    $expectedName=if($bucket -eq 'done'){$meta.assignment_id+'__'+$meta.result}else{$meta.assignment_id}
                    if($expectedName -cne $file.BaseName -or ($meta.owner -and $meta.owner -cne $owner.Name) -or $meta.status -cne $bucket){throw 'assignment identity mismatch'}
                    $state=switch($bucket){inbox{'queued'} in_progress{'in_progress'} done{if($meta.result -ceq 'fail'){'failed'}else{'unverified'}}}
                    $evidenceRef=$null;$validatedAt=$null
                    if($bucket -eq 'done' -and $meta.result -ceq 'pass' -and -not $pending){
                        try{
                            if($meta.validation_evidence -cnotmatch '^[a-f0-9]{32}$'){throw 'invalid evidence id'}
                            $evidencePath=Join-Path (Get-AssignmentEvidenceDirectory $Root) ($meta.validation_evidence+'.json')
                            $e=Read-DashboardFile $evidencePath|ConvertFrom-Json
                            $null=Assert-DashboardPath $e.workspace
                            $null=Read-DashboardFile (Join-Path (Get-AssignmentEvidenceDirectory $Root) ($meta.validation_evidence+'.log'))
                            $e=Assert-AssignmentCompletionEvidence $Root $owner.Name $meta.assignment_id $content -ReadOnly
                            $state='passed';$evidenceRef=Get-RelativeProjectPath $Root $evidencePath;$validatedAt=$e.finished_at
                        }catch{$state='unverified'}
                    }
                    if($pending){$state='unconfirmed'}
                    $worker=@($snapshot.workers|Where-Object{$_.assignment_id -ceq $meta.assignment_id -and $_.owner -ceq $owner.Name})|Select-Object -First 1
                    if($state -eq 'in_progress' -and ($null -eq $worker -or $worker.status -ne 'running')){$state='unconfirmed'}
                    $taskRows.Add([pscustomobject]@{id=(Get-DashboardText $meta.assignment_id);owner=(Get-DashboardText $owner.Name);title=(Get-DashboardText $meta.title);state=$state;source_plan=(Get-DashboardText $meta.source_plan);seed_task_key=(Get-DashboardText $meta.seed_task_key);branch=(Get-DashboardText $meta.feature_branch);worker=$worker;evidence=$evidenceRef;validated_at=$validatedAt;attempts=$null;known_tokens=$null;unknown_usage_count=$null})
                }catch{Add-DashboardAlert 'assignment_invalid' '읽을 수 없는 작업 파일이 있습니다.' '작업 메타데이터와 큐 위치를 확인하세요.'}
            }
        }
    }
    # A transition snapshot can contain both source and destination. Never count
    # that as two tasks or choose the apparently successful copy.
    $tasks=@($taskRows.ToArray())
    foreach($group in @($tasks|Group-Object id)){
        if($group.Count -gt 1){foreach($task in $group.Group){$task.state='unconfirmed'};Add-DashboardAlert 'assignment_duplicate' '중복된 작업 ID가 있습니다.' '큐 전환 기록을 확인하세요.'}
    }
    $snapshot.tasks=@($tasks|Sort-Object id -Unique)
    try{
        $usageDirectory=Get-HarnessUsageDirectory $Root
        foreach($file in @(Get-DashboardFiles $usageDirectory '*.json')){$null=Read-DashboardFile $file.FullName}
        $records=@(Read-HarnessUsageRecords $Root)
        $totals=Get-HarnessUsageTotals $records
        $inputTokens=[decimal]0;$outputTokens=[decimal]0
        $rows=@(foreach($record in $records){
            if($record.status -ceq 'completed' -and $record.usage.status -ceq 'known'){$inputTokens+=$record.usage.input_tokens;$outputTokens+=$record.usage.output_tokens}
            [pscustomobject]@{id=$record.invocation_id;assignment_id=(Get-DashboardText $record.assignment_id);owner=(Get-DashboardText $record.owner);provider=$record.provider;requested_model=(Get-DashboardText $record.requested_model);attempt=$record.attempt;status=$record.status;usage_status=$(if($record.status -ceq 'reserved'){'pending'}else{$record.usage.status});input_tokens=$(if($record.usage.status -ceq 'known'){$record.usage.input_tokens}else{$null});output_tokens=$(if($record.usage.status -ceq 'known'){$record.usage.output_tokens}else{$null});reserved_at=$record.reserved_at;completed_at=$record.completed_at;duration_seconds=$record.duration_seconds}
        })
        $policy=if($configured){Get-HarnessExecutionPolicy $Root}else{$null}
        $snapshot.usage=[pscustomobject]@{status='ok';scope='all_retained_project_invocations';totals=$totals;input_tokens=$inputTokens;output_tokens=$outputTokens;policy=$policy;invocations=$rows;actual_cost_usd=$null;subscription_remaining=$null}
        foreach($task in $snapshot.tasks){$own=@($records|Where-Object{$_.assignment_id -ceq $task.id -and $_.owner -ceq $task.owner});$t=Get-HarnessUsageTotals $own;$task.attempts=$own.Count;$task.known_tokens=$t.known_total_tokens;$task.unknown_usage_count=$t.unknown_usage_count}
        if($totals.unknown_usage_count -gt 0){Add-DashboardAlert 'usage_unknown' '미확정 사용량이 합계에서 제외되어 있습니다.' '토큰 합계는 확인된 사용량입니다. 미확정 호출의 완료 기록을 확인하세요.'}
        if($null -ne $policy){
            foreach($pair in @(@('max_invocations','invocation_count'),@('max_concurrent_workers','reserved_count'),@('max_total_tokens','known_total_tokens'),@('max_total_duration_seconds','completed_duration_seconds'))){
                if($null -ne $policy.($pair[0]) -and $totals.($pair[1]) -ge $policy.($pair[0])){Add-DashboardAlert 'launch_limit' ('다음 실행 한도 도달: '+$pair[0]) '정책과 사용량을 확인하세요. 실행 중인 worker를 중단하는 한도는 아닙니다.'}
            }
            if(($null -ne $policy.max_total_tokens -and $totals.unknown_usage_count -gt 0) -or ($null -ne $policy.max_total_duration_seconds -and $totals.reserved_count -gt 0)){Add-DashboardAlert 'launch_unknown' '미확정 사용량 때문에 다음 실행이 차단될 수 있습니다.' '예약과 완료 기록을 확인하세요.'}
        }
    }catch{$snapshot.usage=[pscustomobject]@{status='unavailable';totals=$null;invocations=@()};Add-DashboardAlert 'usage_invalid' '사용량을 안전하게 집계할 수 없습니다.' '손상되었거나 일치하지 않는 사용량 기록을 확인하세요. 0으로 처리하지 않습니다.'}
    $report=Get-HarnessConfiguredPath $Root 'latest_report' 'harness/reports/latest_report.md'
    if(Test-Path -LiteralPath $report){
        try{
            $text=Read-DashboardFile $report
            $section=[regex]::Match($text,'(?ms)^## Results\s*\r?\n(.*?)(?=^## |\z)').Groups[1].Value
            $fields=Get-DashboardFields $section
            $failureSection=[regex]::Match($text,'(?ms)^## Failures\s*\r?\n(.*?)(?=^## |\z)').Groups[1].Value
            $failure=Get-DashboardFields $failureSection
            $snapshot.validation=[pscustomobject]@{scope='last_completed_cycle';failure_type=(Get-DashboardText $failure.type);failure_module=(Get-DashboardText $failure.module);recorded_at=(Get-Item -LiteralPath $report).LastWriteTimeUtc.ToString('o');steps=@(foreach($stage in @('build','unit','integration','benchmark_smoke')){[pscustomobject]@{name=$stage;status=$(if($fields[$stage] -cin @('pass','fail','skipped','not_run')){$fields[$stage]}else{'unknown'})}})}
            if(@($snapshot.validation.steps|Where-Object{$_.status -eq 'fail'}).Count){Add-DashboardAlert 'cycle_failed' ('최근 검증 실패: '+(Get-DashboardText $failure.type)+' / '+(Get-DashboardText $failure.module)) '로컬 latest_report와 해당 검증 로그에서 원인을 확인하세요.'}
        }catch{Add-DashboardAlert 'validation_invalid' '최근 검증 결과를 읽을 수 없습니다.' 'latest_report를 확인하세요.'}
    }
    $workflowPath=Resolve-HarnessEnginePath $Root 'harness/state/git_workflow/state.json' 'workflow'
    if($configured -and $profile.git_workflow.state_file){$workflowPath=Resolve-HarnessEnginePath $Root $profile.git_workflow.state_file 'workflow'}
    if(Test-Path -LiteralPath $workflowPath){
        try{
            $workflow=Read-DashboardFile $workflowPath|ConvertFrom-Json
            $snapshot.approvals=@(foreach($approval in $workflow.approvals){if($approval.status -ceq 'requested'){[pscustomobject]@{id=(Get-DashboardText $approval.id);source_branch=(Get-DashboardText $approval.source_branch);source_head=(Get-DashboardText $approval.source_head);target_branch=(Get-DashboardText $approval.target_branch);requested_at=$approval.requested_at}}})
        }catch{Add-DashboardAlert 'approvals_invalid' '승인 요청 상태를 읽을 수 없습니다.' 'Git workflow 상태 파일을 확인하세요.'}
    }
}catch{Add-DashboardAlert 'collection_failed' '일부 상태를 안전하게 읽을 수 없습니다.' '프로필, 경로 경계, 파일 권한 및 기록 형식을 확인하세요.'}
foreach($entry in @($observed.GetEnumerator())){
    try{
        $null=Assert-DashboardPath $entry.Key;$item=Get-Item -LiteralPath $entry.Key
        if($entry.Value -ne ([string]$item.Length+':'+[string]$item.LastWriteTimeUtc.Ticks)){throw 'changed'}
    }catch{Add-DashboardAlert 'snapshot_changed' '조회 중 기록이 변경되었습니다.' '다음 갱신 결과를 확인하세요.';break}
}
foreach($path in @($directories.Keys)){
    try{
        $null=Assert-DashboardPath $path
        $items=@(Get-ChildItem -LiteralPath $path -Force -Filter $directories[$path].filter)
        $fingerprint=@($items|Sort-Object Name|ForEach-Object{$_.Name+':'+$_.LastWriteTimeUtc.Ticks}) -join '|'
        if($fingerprint -cne $directories[$path].fingerprint){throw 'changed'}
    }catch{Add-DashboardAlert 'snapshot_changed' '조회 중 큐 또는 기록 목록이 변경되었습니다.' '다음 갱신 결과를 확인하세요.';break}
}
if(@($alerts|Where-Object{$_.code -match 'invalid|collection_failed|changed|duplicate|unresolved'}).Count){$snapshot.collection_status='partial'}
$snapshot.alerts=@($alerts.ToArray())
$snapshot.summary=[pscustomobject]@{total=@($snapshot.tasks).Count;passed=@($snapshot.tasks|Where-Object{$_.state -eq 'passed'}).Count;failed=@($snapshot.tasks|Where-Object{$_.state -eq 'failed'}).Count;queued=@($snapshot.tasks|Where-Object{$_.state -eq 'queued'}).Count;in_progress=@($snapshot.tasks|Where-Object{$_.state -eq 'in_progress'}).Count;unconfirmed=@($snapshot.tasks|Where-Object{$_.state -in @('unconfirmed','unverified')}).Count;running_workers=@($snapshot.workers|Where-Object{$_.status -eq 'running'}).Count;approval_requests=@($snapshot.approvals).Count}
$snapshot|ConvertTo-Json -Depth 20
