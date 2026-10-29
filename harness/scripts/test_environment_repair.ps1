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
# Fake tools are small scripts in a path with spaces and brackets; a marker file stands for "the service is up".
function Fixture($Environment=$null){
    $root=Join-Path $testRoot ('env [safe] '+[Guid]::NewGuid().ToString('N'))
    $profile=@{execution_policy=@{}}
    if($null -ne $Environment){$profile.environment=$Environment}
    Write-Utf8File (Join-Path $root 'harness/project/configs/project_profile.json') ($profile|ConvertTo-Json -Depth 10)
    Ensure-HarnessDirectory (Join-Path $root 'harness/configs')
    Copy-Item -LiteralPath (Join-Path $source 'configs/known_errors.json') -Destination (Join-Path $root 'harness/configs/known_errors.json')
    return $root
}
function Tool([string]$Name,[string]$Body){$path=Join-Path $testRoot ("tools [x]/"+[Guid]::NewGuid().ToString('N')+"-$Name.ps1");Write-Utf8File $path $Body;return $path}
$marker=Join-Path $testRoot 'service up.marker'
$check=Tool 'check' ("if(Test-Path -LiteralPath '"+$marker.Replace("'","''")+"'){exit 0};Write-Output 'service is down';exit 1")
$start=Tool 'start' ("Start-Sleep -Seconds 2;Set-Content -LiteralPath '"+$marker.Replace("'","''")+"' -Value up")
$fails=Tool 'fails' "Write-Output 'install failed';exit 3"
$hangs=Tool 'hangs' 'Start-Sleep -Seconds 30'
function Env($Repairs=@{},$Requirements=@()){return @{version=1;requirements=@($Requirements);repairs=$Repairs}}
# Fixture profiles use the default provider; a fake CLI stands in for it.
$env:HARNESS_CODEX_PATH=Tool 'codex' 'exit 0'

Case security 'environment configuration is validated strictly' {
    foreach($bad in @(
        @{version=2;requirements=@();repairs=@{}},
        @{version=1;requirements=@();repairs=@{};extra=1},
        (Env @{'start-it'=@{description='d';check=@($check);wait_seconds=5}}),
        (Env @{'start-it'=@{description='d';start=@($start);check=@($check);wait_seconds=0}}),
        (Env @{'start-it'=@{description='d';start=@($start);check=@($check);wait_seconds=5;shell='rm -rf /'}}),
        (Env @{'start-it'=@{description='d';start='Docker Desktop.exe --flag';check=@($check);wait_seconds=5}}),
        (Env @{} @(@{id='docker';check=@($check);repair='missing-repair'})),
        (Env @{} @(@{id='Bad Id';check=@($check)})),
        (Env @{} @(@{id='tool';check=@($check);installed='docker --version'})),
        (Env @{} @(@{id='tool';check=@($check);install_hint=@{url='https://example.com'}})),
        (Env @{} @(@{id='tool';check=@($check);install_hint=@{text='get it';url='http://example.com'}})),
        (Env @{} @(@{id='tool';check=@($check);install_hint=@{text='get it';script='x'}})))){
        $root=Fixture $bad
        Reject {Get-HarnessEnvironmentConfig $root}
    }
}
Case integration 'a declared start repair runs once and waits for its check' {
    if(Test-Path -LiteralPath $marker){Remove-Item -LiteralPath $marker}
    $root=Fixture (Env @{'service-start'=@{description='start the fake service';start=@($start);check=@($check);wait_seconds=30}})
    $r=Invoke-HarnessEnvironmentRepair $root 'service-start'
    Assert-True ($r.Success -and (Test-Path -LiteralPath $marker)) "repair failed: $($r.Message)"
    $again=Invoke-HarnessEnvironmentRepair $root 'service-start'
    Assert-True ($again.Success -and $again.Message.Contains('already passes')) 'a passing check ran the repair again'
}
Case integration 'failed, missing, hanging or undeclared repairs report failure' {
    if(Test-Path -LiteralPath $marker){Remove-Item -LiteralPath $marker}
    $root=Fixture (Env @{
        'install-fails'=@{description='install';run=@($fails);check=@($check);wait_seconds=10}
        'not-installed'=@{description='start';start=@((Join-Path $testRoot 'missing tool.exe'));check=@($check);wait_seconds=5}
        'never-up'=@{description='wait';run=@($hangs);check=@($check);wait_seconds=2}})
    $failed=Invoke-HarnessEnvironmentRepair $root 'install-fails'
    Assert-True (-not $failed.Success -and $failed.Message.Contains('install failed')) "wrong: $($failed.Message)"
    Assert-True (-not (Invoke-HarnessEnvironmentRepair $root 'not-installed').Success) 'missing start command passed'
    $timer=[Diagnostics.Stopwatch]::StartNew();$hung=Invoke-HarnessEnvironmentRepair $root 'never-up';$timer.Stop()
    Assert-True (-not $hung.Success -and $timer.Elapsed.TotalSeconds -lt 20) 'a hanging repair was not bounded'
    Assert-True (-not (Invoke-HarnessEnvironmentRepair $root 'docker-start').Success) 'an undeclared repair ran'
}
Case integration 'readiness separates ok, repairable, repaired and needs-decision requirements' {
    if(Test-Path -LiteralPath $marker){Remove-Item -LiteralPath $marker}
    $ok=Tool 'ok' 'exit 0'
    $root=Fixture (Env @{'service-start'=@{description='start';start=@($start);check=@($check);wait_seconds=30}} @(
        @{id='jdk';check=@($ok)},
        @{id='service';check=@($check);repair='service-start'},
        @{id='redis';check=@($fails)}))
    $plain=Get-HarnessEnvironmentReadiness $root
    $state=@{};foreach($i in $plain.requirements){$state[$i.id]=$i.state}
    Assert-True ($plain.status -eq 'blocked' -and $state.jdk -eq 'ok' -and $state.service -eq 'repairable' -and $state.redis -eq 'needs_decision') "wrong: $($plain|ConvertTo-Json -Depth 5 -Compress)"
    Assert-True (-not (Test-Path -LiteralPath $marker)) 'a check without -Repair started the service'
    Assert-True (@($plain.undeclared_repairs) -contains 'docker-start') 'undeclared known-error repair not reported'
    $noisy=Tool 'noisy' ("1..40|ForEach-Object{Write-Output ('plugin line '+`$_)};Write-Output 'Server:';Write-Output 'failed to connect to the docker API';exit 1")
    $short=Get-HarnessEnvironmentReadiness (Fixture (Env @{} @(@{id='docker';check=@($noisy)})))
    $msg=@($short.requirements|Where-Object{$_.id -eq 'docker'})[0].message
    Assert-True ($msg -eq 'plugin line 40 / Server: / failed to connect to the docker API') "check output not summarized: $msg"
    $repaired=Get-HarnessEnvironmentReadiness $root -Repair
    $state=@{};foreach($i in $repaired.requirements){$state[$i.id]=$i.state}
    Assert-True ($state.service -eq 'repaired' -and $repaired.status -eq 'blocked') 'repair or blocking decision wrong'
    $root=Fixture (Env @{} @(@{id='jdk';check=@($ok)}))
    Assert-True ((Get-HarnessEnvironmentReadiness $root).status -eq 'ready') 'ready profile blocked'
    Assert-True ((Get-HarnessEnvironmentReadiness (Fixture)).status -eq 'undeclared' -and (Get-HarnessEnvironmentReadiness (Fixture (Env))).status -eq 'undeclared') 'missing requirements not reported as undeclared'
}
Case integration 'a tool that is not installed is reported with its hint and never repaired' {
    if(Test-Path -LiteralPath $marker){Remove-Item -LiteralPath $marker}
    $ok=Tool 'ok' 'exit 0'
    $absent=Join-Path $testRoot 'not installed [x]/docker.exe'
    $root=Fixture (Env @{'service-start'=@{description='start';start=@($start);check=@($check);wait_seconds=30}} @(
        @{id='docker';check=@($absent,'info');repair='service-start';install_hint=@{text='Install Docker Desktop:';url='https://docs.docker.com/desktop/'}},
        @{id='declared-missing';installed=@($fails);check=@($ok)},
        @{id='installed-but-down';installed=@($ok);check=@($check);repair='service-start'}))
    $report=Get-HarnessEnvironmentReadiness $root -Repair
    $byId=@{};foreach($i in $report.requirements){$byId[$i.id]=$i}
    Assert-True ($report.status -eq 'blocked' -and $byId.docker.state -eq 'missing' -and $byId['declared-missing'].state -eq 'missing') "wrong: $($report|ConvertTo-Json -Depth 5 -Compress)"
    Assert-True ($byId.docker.message.Contains('https://docs.docker.com/desktop/') -and $byId.docker.message.Contains('harness.ps1 env')) "hint missing: $($byId.docker.message)"
    Assert-True ($byId['declared-missing'].message.Contains('no install hint declared')) 'missing hint not reported'
    Assert-True ($byId['installed-but-down'].state -eq 'repaired') 'an installed tool was not repaired'
    # Only the installed tool's repair ran; the missing docker never triggered a start.
    $missingOnly=Fixture (Env @{'service-start'=@{description='start';start=@($start);check=@($check);wait_seconds=30}} @(@{id='docker';check=@($absent,'info');repair='service-start'}))
    if(Test-Path -LiteralPath $marker){Remove-Item -LiteralPath $marker}
    $null=Get-HarnessEnvironmentReadiness $missingOnly -Repair
    Assert-True (-not (Test-Path -LiteralPath $marker)) 'a repair ran for a tool that is not installed'
}
Case integration 'tools the harness itself runs are checked before project tools' {
    $root=Fixture
    $report=Get-HarnessEnvironmentReadiness $root
    $ids=@($report.requirements|Where-Object{$_.source -eq 'harness'}|ForEach-Object{$_.id})
    Assert-True (($ids -join ',') -eq 'harness-git,harness-provider' -and $report.status -eq 'undeclared') "wrong: $($report|ConvertTo-Json -Depth 5 -Compress)"
    $saved=$env:HARNESS_CODEX_PATH
    try{
        $env:HARNESS_CODEX_PATH=Join-Path $testRoot 'no codex here.exe'
        $report=Get-HarnessEnvironmentReadiness $root
        $provider=@($report.requirements|Where-Object{$_.id -eq 'harness-provider'})[0]
        Assert-True ($report.status -eq 'blocked' -and $provider.state -eq 'missing' -and $provider.message.Contains('https://github.com/openai/codex')) "missing provider not blocking: $($report|ConvertTo-Json -Depth 5 -Compress)"
    }finally{$env:HARNESS_CODEX_PATH=$saved}
}
# Field finding F-23: a started service (Docker Desktop) inherited the caller's output
# pipe, so a parent that captures harness output waited until the service exited.
Case integration 'a started service does not hold the caller output open' {
    $pidFile=Join-Path $testRoot ('daemon '+[Guid]::NewGuid().ToString('N')+'.pid')
    $daemon=Tool 'daemon' ("Set-Content -LiteralPath '"+$pidFile.Replace("'","''")+"' -Value `$PID;Write-Output 'daemon output';Start-Sleep -Seconds 40")
    $common=(Join-Path $PSScriptRoot 'harness_common.ps1').Replace("'","''")
    $starter=Tool 'starter' (". '$common';`$null=Start-HarnessArgvProcess @('"+$daemon.Replace("'","''")+"') (Get-Location).Path -Detached;Write-Output 'started'")
    $timer=[Diagnostics.Stopwatch]::StartNew()
    try{
        $result=Invoke-HarnessProcess (Get-HarnessPowerShellExecutable) @('-NoProfile','-ExecutionPolicy','Bypass','-File',$starter) -AllowFailure
        $timer.Stop()
        Assert-True ($result.Success -and $result.Output.Contains('started')) "starter failed: $($result.Output)"
        Assert-True ($timer.Elapsed.TotalSeconds -lt 25) "caller waited $([int]$timer.Elapsed.TotalSeconds)s for the started service"
        Assert-True (-not $result.Output.Contains('daemon output')) 'service output reached the caller'
        $deadline=[DateTime]::UtcNow.AddSeconds(15)
        while(-not (Test-Path -LiteralPath $pidFile) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 200}
        Assert-True (Test-Path -LiteralPath $pidFile) 'the detached service did not start'
    }finally{
        if(Test-Path -LiteralPath $pidFile){$daemonPid=[int](Get-Content -LiteralPath $pidFile -Raw).Trim();Stop-Process -Id $daemonPid -Force -ErrorAction SilentlyContinue}
    }
}
Case unit 'environment failures with a declared repair are repaired, others stop' {
    $withRepair=New-HarnessFailureClassification 'environment' 'docker-unavailable' 'docker down' ([pscustomobject]@{id='docker-unavailable';repair='docker-start'})
    $decision=Get-HarnessFailureDecision $withRepair ([pscustomobject]@{attempts=@()})
    Assert-True ($decision.action -eq 'repair' -and $decision.repair -eq 'docker-start') 'repair not chosen'
    $without=New-HarnessFailureClassification 'environment' 'command-not-found' 'missing tool' ([pscustomobject]@{id='command-not-found';repair=$null})
    Assert-True ((Get-HarnessFailureDecision $without ([pscustomobject]@{attempts=@()})).action -eq 'stop_needs_operator') 'unrepairable environment failure was retried'
}

# Dispatcher: a repaired environment retries without using a worker attempt; a failed repair stops.
$dispatchAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'dispatch_seed_plan.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Get-LatestAttemptFailure','New-WorkerOutcome','Invoke-AssignmentWorkerWithRetry')){
    $definition=$dispatchAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$DryRun=$false;$PreflightOnly=$false;$ProviderRetryDelaySeconds=0;$providerRetryLimit=2;$environmentRepairLimit=2
function Get-AssignmentLifecycleRecord($Owner,$AssignmentId){return [pscustomobject]@{State='done';Result=$script:lastResult}}
function Requeue-FailedAssignment($Owner,$AssignmentId,$NextAttempt,$FailureContext){$script:requeues++}
function Invoke-HarnessEnvironmentRepair($RootDir,$RepairId){$script:repairCalls++;return [pscustomobject]@{Success=$script:repairWorks;Message="fake $RepairId"}}
function Invoke-AssignmentWorker($Owner,$CurrentAssignmentId){
    $step=$script:scenario[$script:launches];$script:launches++
    if($step -eq 'pass'){$script:lastResult='pass';return [pscustomobject]@{Success=$true;ExitCode=0;Output='ok'}}
    $worker=[pscustomobject]@{version=1;invocation_id=[Guid]::NewGuid().ToString('N');assignment_id=$CurrentAssignmentId;owner='tester';root=[IO.Path]::GetFullPath($rootDir);status='settled'}
    Write-Utf8File (Get-AssignmentWorkerPaths $rootDir $CurrentAssignmentId).Record ($worker|ConvertTo-Json)
    $null=Save-HarnessAttemptClassification $rootDir $worker (New-HarnessFailureClassification 'environment' 'docker-unavailable' 'docker down' ([pscustomobject]@{id='docker-unavailable';repair='docker-start'}))
    $script:lastResult='fail'
    return [pscustomobject]@{Success=$false;ExitCode=1;Output='worker failed'}
}
function Run-Scenario([string[]]$Steps,[bool]$RepairWorks,[int]$MaxAttempts=1){
    $script:rootDir=Fixture;$script:scenario=$Steps;$script:launches=0;$script:requeues=0;$script:repairCalls=0;$script:repairWorks=$RepairWorks;$script:MaxWorkerAttempts=$MaxAttempts
    return Invoke-AssignmentWorkerWithRetry -Owner 'tester' -AssignmentId 'task'
}
Case integration 'a repaired environment retries without using a worker attempt' {
    $o=Run-Scenario @('docker','pass') $true 1
    Assert-True ($o.Success -and $script:repairCalls -eq 1 -and $script:launches -eq 2) "wrong: $($o|ConvertTo-Json -Compress)"
}
Case integration 'a failed repair stops and repeated repairs are bounded' {
    $o=Run-Scenario @('docker','pass') $false
    Assert-True ($o.StopKind -eq 'needs_operator' -and $o.StopReason.Contains('repair failed') -and $script:launches -eq 1) "wrong: $($o|ConvertTo-Json -Compress)"
    $o=Run-Scenario @('docker','docker','docker','pass') $true
    Assert-True ($o.StopKind -eq 'needs_operator' -and $script:repairCalls -eq 2 -and $script:launches -eq 3) "repairs unbounded: $($o|ConvertTo-Json -Compress)"
}

Write-Utf8File (Join-Path $testRoot 'results.json') ($results.ToArray()|ConvertTo-Json -Depth 8)
$failed=@($results|Where-Object{-not $_.passed}).Count
Write-Output "Environment results: $($results.Count-$failed)/$($results.Count) passed; artifacts: $testRoot"
if($failed){exit 1}
