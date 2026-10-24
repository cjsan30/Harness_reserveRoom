param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
. (Join-Path $PSScriptRoot 'harness_cli.ps1')
$source=Split-Path -Parent $PSScriptRoot
if(-not $OutputDirectory){$OutputDirectory=Join-Path $source '.test-output'}
$testRoot=Join-Path $OutputDirectory ([Guid]::NewGuid().ToString('N'))
Ensure-HarnessDirectory $testRoot
$results=New-Object 'System.Collections.Generic.List[object]'
function Assert-True($Value,[string]$Message){if(-not $Value){throw $Message}}
function Test-Case([string]$Kind,[string]$Name,[scriptblock]$Body){
    try{& $Body;$results.Add(@{kind=$Kind;name=$Name;passed=$true});Write-Output "PASS [$Kind] $Name"}
    catch{$results.Add(@{kind=$Kind;name=$Name;passed=$false;error=$_.Exception.Message});Write-Output "FAIL [$Kind] $Name : $($_.Exception.Message)"}
}
function Call-Cli([object[]]$Tokens){
    # Same safe transport as the CLI uses for a child; tokens remain separate data.
    $payload=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@($Tokens)|ConvertTo-Json -Compress)))
    $script=Join-Path $PSScriptRoot 'harness.ps1'
    $code="[object[]]`$items=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payload'))|ConvertFrom-Json; & '"+$script.Replace("'","''")+"' @items; exit `$LASTEXITCODE"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    return Invoke-HarnessProcess (Get-HarnessPowerShellExecutable) @('-NoProfile','-EncodedCommand',$encoded) -AllowFailure
}
Test-Case unit 'help needs no profile or target' {
    $r=Call-Cli @('help','-Json');$j=$r.Output|ConvertFrom-Json
    Assert-True ($r.Success -and $j.schema_version -eq 1 -and $j.output.Contains('-Preview')) $r.Output
}
foreach($tokens in @(@('unknown'),@('status','-Force'),@('run'),@('resume','-PlanFile','plan.md','-Model','x'),@('run','-PlanFile','p','-MaxWorkerAttempts','0'),@('run','-PlanFile','p','-DryRun','-PreflightOnly'),@('status','-Json','-Json'),@('init','-ProjectName'))){
    Test-Case unit ('invalid options: '+($tokens -join ' ')) {
        $blocked=$false;try{Get-HarnessCliRequest $tokens|Out-Null}catch{$blocked=$true}
        Assert-True $blocked 'invalid arguments accepted'
    }
}
Test-Case unit 'usage errors return code 2 and parseable JSON' {
    $r=Call-Cli @('unknown','-Json');$j=$r.Output|ConvertFrom-Json
    Assert-True ($r.ExitCode -eq 2 -and $j.exit_code -eq 2 -and $null -eq $j.child_exit_code) $r.Output
}

$unicode=[string][char]0xD55C+[char]0xAE00
foreach($layout in @('standalone','nested')){
    $root=Join-Path $testRoot ($layout+' '+$unicode+' [safe]')
    $engine=if($layout -eq 'nested'){Join-Path $root 'harness'}else{$root}
    Ensure-HarnessDirectory $engine
    foreach($dir in @('scripts','configs','docs','project','githooks')){Copy-Item -LiteralPath (Join-Path $source $dir) -Destination (Join-Path $engine $dir) -Recurse}
    Copy-Item -LiteralPath (Join-Path $source 'AGENT.md') -Destination (Join-Path $engine 'AGENT.md')
    Write-Utf8File (Join-Path $root 'plan.md') '- plan_id: cli-fixture'
    Test-Case integration "$layout preview does not initialize profile or install hooks" {
        $r=Call-Cli @('init','-Root',$root,'-ProjectName','fixture','-Preview','-Json');$j=$r.Output|ConvertFrom-Json
        Assert-True ($r.Success -and $j.execution_status -eq 'preview' -and $j.data.Script -eq (Join-Path $engine 'scripts/init_project_adapter.ps1')) $r.Output
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $engine 'project/configs/project_profile.json'))) 'preview initialized profile'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.githooks'))) 'preview installed hooks'
    }
    Test-Case integration "$layout real init and structured status" {
        $r=Call-Cli @('init','-Root',$root,'-ProjectName','cli-fixture','-Language','c11','-Framework','none','-Json')
        Assert-True $r.Success $r.Output
        Assert-True (Test-Path -LiteralPath (Join-Path $engine 'project/configs/project_profile.json')) 'profile missing'
        $r=Call-Cli @('status','-Root',$root,'-Json');$j=$r.Output|ConvertFrom-Json
        Assert-True ($r.Success -and $j.execution_status -eq 'succeeded' -and $null -ne $j.data.status) $r.Output
    }
    Test-Case integration "$layout doctor failure is normalized and preserves child code" {
        $r=Call-Cli @('doctor','-Root',$root,'-Json');$j=$r.Output|ConvertFrom-Json
        Assert-True ($r.ExitCode -eq 1 -and $j.child_exit_code -ne 0 -and $j.execution_status -eq 'failed') $r.Output
        $installed=@(Get-ChildItem -LiteralPath (Join-Path $root '.githooks') -File -ErrorAction SilentlyContinue)
        Assert-True ($installed.Count -eq 0) 'doctor installed hook files'
    }
    Test-Case unit "$layout run and resume choose explicit backends" {
        foreach($command in @('run','resume')){
            $r=Get-HarnessCliRequest @($command,'-Root',$root,'-PlanFile','plan.md')
            $p=Get-HarnessCliPlan $r $PSScriptRoot
            $expected=if($command -eq 'run'){'run_seed_handoff.ps1'}else{'get_seed_handoff_resume.ps1'}
            Assert-True ((Split-Path -Leaf $p.Script) -eq $expected) 'wrong backend'
        }
        $p=Get-HarnessCliPlan (Get-HarnessCliRequest @('resume','-Execute','-Root',$root,'-PlanFile','plan.md','-MaxWorkerAttempts','2')) $PSScriptRoot
        Assert-True ($p.Parameters.Resume -and $p.Parameters.MaxWorkerAttempts -eq 2 -and (Split-Path -Leaf $p.Script) -eq 'run_seed_handoff.ps1') 'live resume mapping wrong'
    }
    Test-Case security "$layout input path cannot escape target" {
        $blocked=$false
        try{Get-HarnessCliPlan (Get-HarnessCliRequest @('run','-Root',$root,'-PlanFile','../outside.md')) $PSScriptRoot|Out-Null}catch{$blocked=$true}
        Assert-True $blocked 'path escape accepted'
    }
}

# A local fake command records actual bound data; no AI or project commands run.
$fakeRoot=Join-Path $testRoot 'transport [safe]';$fakeEngine=Join-Path $fakeRoot 'harness'
Write-Utf8File (Join-Path $fakeEngine 'scripts/init_project_adapter.ps1') @'
param([string]$ProjectName,[string]$Requirements,[switch]$Force)
[pscustomobject]@{name=$ProjectName;requirements=$Requirements;force=[bool]$Force;root=$env:CODEX_HARNESS_ROOT;workspace=$env:CODEX_GIT_WORKSPACE_ROOT}|ConvertTo-Json
'@
Test-Case security 'quotes newlines and shell metacharacters remain literal arguments' {
    $value='literal "quotes"; $(throw ''injected'') & | > '+$unicode+"`nsecond line"
    $oldRoot=$env:CODEX_HARNESS_ROOT;$oldWorkspace=$env:CODEX_GIT_WORKSPACE_ROOT
    try{
        $env:CODEX_HARNESS_ROOT='unrelated';$env:CODEX_GIT_WORKSPACE_ROOT='unrelated'
        $r=Call-Cli @('init','-Root',$fakeRoot,'-ProjectName',$value,'-Requirements',$value,'-Force','-Json')
        $envelope=$r.Output|ConvertFrom-Json;$data=$envelope.output|ConvertFrom-Json
        Assert-True ($r.Success -and $data.name -ceq $value -and $data.requirements -ceq $value -and $data.force -and $data.root -eq $fakeRoot -and -not $data.workspace) $r.Output
        Assert-True ($env:CODEX_HARNESS_ROOT -eq 'unrelated' -and $env:CODEX_GIT_WORKSPACE_ROOT -eq 'unrelated') 'parent environment changed'
    }finally{$env:CODEX_HARNESS_ROOT=$oldRoot;$env:CODEX_GIT_WORKSPACE_ROOT=$oldWorkspace}
}
Write-Utf8File (Join-Path $fakeEngine 'scripts/run_harness_preflight.ps1') 'Write-Output "failed assertion"; exit 7'
Write-Utf8File (Join-Path $fakeRoot 'plan.md') '- plan_id: fake-only'
Write-Utf8File (Join-Path $fakeEngine 'scripts/run_seed_handoff.ps1') @'
param([string]$PlanFile,[switch]$Resume,[switch]$DryRun,[int]$MaxWorkerAttempts)
[pscustomobject]@{plan=$PlanFile;resume=[bool]$Resume;dry_run=[bool]$DryRun;attempts=$MaxWorkerAttempts}|ConvertTo-Json
'@
Test-Case integration 'run and execute-resume forward exact options to fake handoff' {
    foreach($command in @('run','resume')){
        $tokens=@($command,'-Root',$fakeRoot,'-PlanFile','plan.md','-DryRun','-MaxWorkerAttempts','2','-Json')
        if($command -eq 'resume'){$tokens+='-Execute'}
        $r=Call-Cli $tokens;$j=$r.Output|ConvertFrom-Json;$data=$j.output|ConvertFrom-Json
        Assert-True ($r.Success -and $data.plan -eq (Join-Path $fakeRoot 'plan.md') -and $data.dry_run -and $data.attempts -eq 2 -and $data.resume -eq ($command -eq 'resume')) $r.Output
    }
}
Test-Case security 'preview never invokes a selected backend' {
    $r=Call-Cli @('doctor','-Root',$fakeRoot,'-Preview','-Json');$j=$r.Output|ConvertFrom-Json
    Assert-True ($r.Success -and $j.execution_status -eq 'preview' -and $null -eq $j.child_exit_code -and -not $j.output) 'preview ran the exit-7 backend'
}
Test-Case integration 'child nonzero result is never converted to CLI success' {
    $r=Call-Cli @('doctor','-Root',$fakeRoot,'-Json');$j=$r.Output|ConvertFrom-Json
    Assert-True ($r.ExitCode -eq 1 -and $j.child_exit_code -eq 7 -and $j.output.Contains('failed assertion')) $r.Output
}
Test-Case security 'arbitrary script command cannot be selected' {
    $r=Call-Cli @('../scripts/complete_assignment.ps1','-Json')
    Assert-True ($r.ExitCode -eq 2) 'arbitrary script command accepted'
}
Write-Utf8File (Join-Path $testRoot 'results.json') ($results.ToArray()|ConvertTo-Json -Depth 8)
$failed=@($results|Where-Object{-not $_.passed}).Count
Write-Output "CLI results: $($results.Count-$failed)/$($results.Count) passed; artifacts: $testRoot"
if($failed){exit 1}
