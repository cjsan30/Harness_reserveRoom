# Intentionally parse raw arguments so unsupported options share exit code 2.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
. (Join-Path $PSScriptRoot 'harness_cli.ps1')
$jsonRequested=(@($args|Where-Object{$_ -ieq '-Json' -or $_ -ieq '--Json'}).Count -gt 0)
$code=0;$childCode=$null;$data=$null;$output='';$plan=$null;$request=$null;$state='failed'
try {$request=Get-HarnessCliRequest @($args)}catch{$code=2;$output=$_.Exception.Message}
if($null -ne $request){
    $jsonRequested=[bool]$request.Options.Json
    try {
        if($request.Command -eq 'help'){$output=Get-HarnessCliHelp;$state='succeeded'}
        else {
            $plan=Get-HarnessCliPlan $request $PSScriptRoot
            if($request.Options.Preview){$state='preview';$data=$plan}
            elseif($request.Command -eq 'dashboard' -and -not $request.Options.Snapshot){
                $oldRoot=$env:CODEX_HARNESS_ROOT;$oldWorkspace=$env:CODEX_GIT_WORKSPACE_ROOT
                try{
                    $env:CODEX_HARNESS_ROOT=$plan.Root;$env:CODEX_GIT_WORKSPACE_ROOT=$null
                    $parameters=$plan.Parameters
                    & $plan.Script @parameters
                    $childCode=$LASTEXITCODE
                    if($childCode -ne 0){$code=1}else{$state='succeeded'}
                }finally{$env:CODEX_HARNESS_ROOT=$oldRoot;$env:CODEX_GIT_WORKSPACE_ROOT=$oldWorkspace}
            }
            else {
                $result=Invoke-HarnessCliPlan $plan
                $childCode=$result.ExitCode;$output=$result.Output
                if($result.Success){
                    $state='succeeded'
                    if($plan.Structured){$data=$output|ConvertFrom-Json;$output=''}
                }else{$code=1}
            }
        }
    }catch{$code=1;$state='failed';$output=$_.Exception.Message}
}
if($jsonRequested){
    [pscustomobject]@{schema_version=1;command=$(if($request){$request.Command}else{$null});execution_status=$state;exit_code=$code;child_exit_code=$childCode;data=$data;output=$output}|ConvertTo-Json -Depth 20
}elseif($state -eq 'preview'){$data|ConvertTo-Json -Depth 10}else{Write-Output $output}
exit $code
