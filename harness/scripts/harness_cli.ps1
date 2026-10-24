# The CLI resolves only this allowlist; user input is never evaluated as code.
function Get-HarnessCliRequest([object[]]$Tokens) {
    $command='help';$offset=0
    if($Tokens.Count -gt 0){$command=([string]$Tokens[0]).ToLowerInvariant();$offset=1}
    if($command -in @('-h','--help','-help')){$command='help'}
    $schemas=@{
        help=@();init=@('ProjectName','Requirements','RequirementsFile','Language','Runtime','Framework','Ide','ApplicationType','Force','ListPresets')
        doctor=@();status=@();usage=@();test=@('SyntaxOnly')
        dashboard=@('Port','RefreshSeconds','PythonExecutable','NoOpen','Snapshot')
        run=@('PlanFile','Model','MaxWorkerAttempts','StaleAfterSeconds','DryRun','PreflightOnly','Ephemeral','StopOnWorkerFailure','SkipAutoAdvanceGit')
        resume=@('PlanFile','StaleAfterSeconds','Execute','Model','MaxWorkerAttempts','DryRun','PreflightOnly','Ephemeral','StopOnWorkerFailure','SkipAutoAdvanceGit')
    }
    if(-not $schemas.ContainsKey($command)){throw 'unknown command; use help'}
    $switches=@('Json','Preview','Force','ListPresets','SyntaxOnly','Execute','DryRun','PreflightOnly','Ephemeral','StopOnWorkerFailure','SkipAutoAdvanceGit','NoOpen','Snapshot')
    $allowed=@('Root','Json','Preview')+$schemas[$command];$options=@{}
    for($i=$offset;$i -lt $Tokens.Count;$i++){
        $token=[string]$Tokens[$i]
        if($token -notmatch '^--?([a-zA-Z]+)$'){throw 'expected a named option; use help'}
        $key=@($allowed|Where-Object{$_ -ieq $Matches[1]})|Select-Object -First 1
        if(-not $key){throw 'option is not supported by this command; use help'}
        if($options.ContainsKey($key)){throw "duplicate option: $key"}
        if($key -in $switches){$options[$key]=$true;continue}
        $i++
        if($i -ge $Tokens.Count -or [string]::IsNullOrWhiteSpace([string]$Tokens[$i]) -or [string]$Tokens[$i] -match '^--?[a-zA-Z]+$'){throw "option requires a value: $key"}
        $options[$key]=[string]$Tokens[$i]
    }
    foreach($key in @('MaxWorkerAttempts','StaleAfterSeconds')){
        if($options.ContainsKey($key)){
            $value=0
            if(-not [int]::TryParse($options[$key],[ref]$value) -or $value -lt 1){throw "option must be a positive integer: $key"}
            $options[$key]=$value
        }
    }
    if($command -in @('run','resume') -and -not $options.ContainsKey('PlanFile')){throw 'run/resume requires -PlanFile; implicit latest-plan selection is not supported'}
    if($options.DryRun -and $options.PreflightOnly){throw 'choose either -DryRun or -PreflightOnly'}
    if($command -eq 'dashboard'){
        if($options.Json -and -not $options.Preview -and -not $options.Snapshot){throw 'dashboard server streams its URL; use -Snapshot -Json for a JSON query'}
        foreach($key in @('Port','RefreshSeconds')){
            if($options.ContainsKey($key)){
                $value=0;$min=if($key -eq 'Port'){0}else{5};$max=if($key -eq 'Port'){65535}else{300}
                if(-not [int]::TryParse($options[$key],[ref]$value) -or $value -lt $min -or $value -gt $max){throw "invalid dashboard option: $key"}
                $options[$key]=$value
            }
        }
        if($options.Snapshot -and @('Port','RefreshSeconds','PythonExecutable','NoOpen'|Where-Object{$options.ContainsKey($_)}).Count){throw 'server options cannot be used with -Snapshot'}
    }
    if($command -eq 'resume' -and -not $options.Execute){
        foreach($key in @('Model','MaxWorkerAttempts','DryRun','PreflightOnly','Ephemeral','StopOnWorkerFailure','SkipAutoAdvanceGit')){
            if($options.ContainsKey($key)){throw 'worker options on resume require -Execute'}
        }
    }
    return [pscustomobject]@{Command=$command;Options=$options}
}

function Get-HarnessCliPlan($Request,[string]$ScriptDirectory) {
    $options=$Request.Options
    $root=if($options.ContainsKey('Root')){[IO.Path]::GetFullPath($options.Root)}else{Get-HarnessRoot $ScriptDirectory}
    if(-not (Test-Path -LiteralPath $root -PathType Container)){throw 'target root does not exist'}
    $engine=Get-HarnessEngineRoot $root
    $scripts=@{init='init_project_adapter.ps1';doctor='run_harness_preflight.ps1';run='run_seed_handoff.ps1';resume='get_seed_handoff_resume.ps1';status='get_harness_status.ps1';usage='get_execution_usage.ps1';test='test_harness.ps1';dashboard='start_harness_dashboard.ps1'}
    $name=$scripts[$Request.Command]
    if($Request.Command -eq 'resume' -and $options.Execute){$name='run_seed_handoff.ps1'}
    if($Request.Command -eq 'dashboard' -and $options.Snapshot){$name='get_harness_dashboard.ps1'}
    $path=Join-Path $engine ('scripts/'+$name)
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw 'target does not contain the required Harness command'}
    $parameters=@{}
    foreach($key in $options.Keys){if($key -notin @('Root','Json','Preview','Execute','Snapshot')){$parameters[$key]=$options[$key]}}
    foreach($key in @('PlanFile','RequirementsFile')){
        if($parameters.ContainsKey($key)){
            $resolved=Resolve-ProjectPath $root $parameters[$key] ('cli.'+$key)
            if(-not (Test-Path -LiteralPath $resolved -PathType Leaf)){throw "input file does not exist: $key"}
            $parameters[$key]=$resolved
        }
    }
    if($Request.Command -eq 'resume' -and $options.Execute){$parameters.Resume=$true}
    $structured=($Request.Command -in @('status','usage') -or ($Request.Command -eq 'resume' -and -not $options.Execute))
    if($options.Json -and $structured){$parameters.Json=$true}
    if($Request.Command -eq 'dashboard' -and $options.Snapshot){$structured=$true}
    return [pscustomobject]@{Root=$root;Script=$path;Parameters=$parameters;Structured=($options.Json -and $structured)}
}

function Invoke-HarnessCliPlan($Plan) {
    # UTF-8 JSON inside an encoded, fixed bootstrap preserves quotes/newlines and
    # metacharacters across Windows PowerShell 5.1 and PowerShell 7.
    $payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Plan|ConvertTo-Json -Depth 10 -Compress)))
    $bootstrap=@'
$ErrorActionPreference='Stop'
$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__'))|ConvertFrom-Json
$env:CODEX_HARNESS_ROOT=$p.Root
$env:CODEX_GIT_WORKSPACE_ROOT=$null
Set-Location -LiteralPath $p.Root
$parameters=@{}
foreach($property in $p.Parameters.PSObject.Properties){$parameters[$property.Name]=$property.Value}
$global:LASTEXITCODE=0
& $p.Script @parameters
$succeeded=$?
if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
if(-not $succeeded){exit 1}
exit 0
'@
    $bootstrap=$bootstrap.Replace('__PAYLOAD__',$payload)
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
    $arguments=@('-NoProfile');if(Test-HarnessIsWindows){$arguments+=@('-ExecutionPolicy','Bypass')}
    $arguments+=@('-EncodedCommand',$encoded)
    return Invoke-HarnessProcess (Get-HarnessPowerShellExecutable) $arguments -AllowFailure
}

function Get-HarnessCliHelp {
    return @'
Harness CLI: pwsh -NoProfile -File scripts/harness.ps1 <command> [options]
Nested layout: use harness/scripts/harness.ps1 from the target repository.

  init     Initialize adapter: -ProjectName -Requirements/-RequirementsFile
           -Language -Runtime -Framework -Ide -ApplicationType -Force -ListPresets
  doctor   Run existing preflight; writes a diagnostic report, installs no hooks
  run      Run seed handoff (live by default): -PlanFile <file>
  resume   Report seed recovery state: -PlanFile <file>; -Execute runs recovery
  status   Refresh project status (query success does not mean project success)
  usage    Read recorded execution usage
  dashboard Start a local read-only web monitor; Ctrl+C stops the server
           -Port 0..65535 -RefreshSeconds 5..300 -PythonExecutable <path> -NoOpen
           -Snapshot [-Json] reads once without Python, a server or writes
  test     Engine self-tests; -SyntaxOnly checks parsers/configuration JSON
  help     Show this help

Common: -Root <repository> -Json -Preview
Preview resolves a call without running it or writing artifacts.
Json emits one v1 envelope with execution_status, child_exit_code, output and data.
Run / resume -Execute: -Model -MaxWorkerAttempts -StaleAfterSeconds -Ephemeral
  -DryRun | -PreflightOnly -StopOnWorkerFailure -SkipAutoAdvanceGit
DryRun uses the existing workflow: it can install hooks and write preview reports.
Use -Preview for a side-effect-free call plan. Resume reports never force cleanup.
Exit: 0 call succeeded/preview, 1 execution failed, 2 invalid CLI arguments.
Existing scripts remain available. No implicit provider fallback or main approval.
'@
}
