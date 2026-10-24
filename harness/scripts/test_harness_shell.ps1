param([string]$OutputDirectory='', [switch]$BaselineOnly, [string]$CasePattern='*')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$source=Split-Path -Parent $PSScriptRoot
if(-not $OutputDirectory){$OutputDirectory=Join-Path $source '.test-output'}
$testRoot=Join-Path $OutputDirectory ([Guid]::NewGuid().ToString('N'));Ensure-HarnessDirectory $testRoot
$results=New-Object 'System.Collections.Generic.List[object]'
function Assert-True($Value,[string]$Message){if(-not $Value){throw $Message}}
function Case([string]$Kind,[string]$Name,[scriptblock]$Body){if($Name -notlike $CasePattern){return};try{& $Body;$results.Add(@{kind=$Kind;name=$Name;passed=$true});Write-Output "PASS [$Kind] $Name"}catch{$results.Add(@{kind=$Kind;name=$Name;passed=$false;error=$_.Exception.Message});Write-Output "FAIL [$Kind] $Name : $($_.Exception.Message)"}}
if($CasePattern -ne '*'){Write-Output "Shell case filter: $CasePattern"}
function ShellQuote([string]$Value){if(Test-HarnessIsWindows){return '"'+$Value+'"'};return "'"+$Value.Replace("'","'\''")+"'"}
$git=(Get-Command git).Source
$shell=if(Test-HarnessIsWindows){Join-Path (Split-Path -Parent (Split-Path -Parent $git)) 'bin/sh.exe'}else{(Get-Command sh).Source}
if(-not(Test-Path -LiteralPath $shell)){throw 'Git POSIX shell required'}
$node=(Get-Command node -ErrorAction Stop).Source
$oldPath=$env:PATH;$oldPs=$env:CODEX_HARNESS_PWSH;$oldRoot=$env:CODEX_HARNESS_ROOT;$oldWorkspace=$env:CODEX_GIT_WORKSPACE_ROOT;$oldActive=$env:HARNESS_VALIDATION_ACTIVE
$oldCi=$env:HARNESS_CI_MODE;$oldNotify=$env:HARNESS_NOTIFY_DISABLED
function RunShell([string]$Script,[string[]]$Arguments=@()){
    return Invoke-HarnessProcess $shell (@($Script.Replace('\','/'))+$Arguments) -WorkingDirectory $testRoot -AllowFailure
}
function SaveProfile {Write-Utf8File $profilePath ($profile|ConvertTo-Json -Depth 20);Clear-ProjectProfileCache $root}
try{
    $env:CODEX_HARNESS_ROOT=$null;$env:CODEX_GIT_WORKSPACE_ROOT=$null;$env:HARNESS_VALIDATION_ACTIVE=$null
    # Command routing is under test; local branch approval is covered separately.
    $env:HARNESS_CI_MODE='true';$env:HARNESS_NOTIFY_DISABLED='1'
    $env:CODEX_HARNESS_PWSH=(Get-HarnessPowerShellExecutable).Replace('\','/')
    $fakeBin=Join-Path $testRoot 'fake-bin';Ensure-HarnessDirectory $fakeBin
    Write-Utf8File (Join-Path $fakeBin 'make') "#!/bin/sh`nprintf 'wrong make invoked\n' >> fake_make_called`nexit 0`n"
    if(-not(Test-HarnessIsWindows)){Invoke-HarnessProcess chmod @('+x',(Join-Path $fakeBin 'make'))|Out-Null}
    $env:PATH=$fakeBin+[IO.Path]::PathSeparator+(Split-Path -Parent $shell)+[IO.Path]::PathSeparator+$oldPath
    foreach($layout in @('standalone','nested')){
        $unicode=[string][char]0xD55C+[char]0xAE00
        $root=Join-Path $testRoot ("$layout $unicode [safe] & project")
        $engine=if($layout -eq 'standalone'){$root}else{Join-Path $root 'harness'}
        Ensure-HarnessDirectory $engine
        foreach($dir in @('scripts','configs','docs','project','githooks')){Copy-Item -LiteralPath (Join-Path $source $dir) -Destination (Join-Path $engine $dir) -Recurse}
        Copy-Item -LiteralPath (Join-Path $source 'AGENT.md') -Destination (Join-Path $engine 'AGENT.md')
        Invoke-HarnessProcess git @('init','-b','main',$root)|Out-Null
        $profilePath=Join-Path $engine 'project/configs/project_profile.json'
        $init=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/init_project_adapter.ps1') @('-ProjectName','shell-fixture','-Language','javascript','-Framework','none','-Force') -AllowFailure
        Assert-True $init.Success $init.Output
        $profile=[IO.File]::ReadAllText($profilePath)|ConvertFrom-Json
        $toolDir=Join-Path $root 'small tool';Ensure-HarnessDirectory $toolDir
        Write-Utf8File (Join-Path $toolDir 'sum.cjs') "const values=process.argv.slice(2).map(Number);if(values.some(x=>!Number.isFinite(x)))process.exit(17);console.log(values.reduce((a,b)=>a+b,0));"
        $check=@'
const fs=require('fs'),path=require('path'),cp=require('child_process'),assert=require('assert');
const step=process.argv[2],root=process.cwd(),out=path.join(root,'tool_out');fs.mkdirSync(out,{recursive:true});
fs.appendFileSync(path.join(out,'calls.jsonl'),JSON.stringify({step,cwd:root,args:process.argv.slice(3)})+'\n');
const tool=path.join(root,'small tool','sum.cjs'),built=path.join(out,'sum.cjs');
if(step==='build'){fs.copyFileSync(tool,built);assert(fs.readFileSync(built).length>0);}
else if(step==='unit'){assert.equal(cp.execFileSync(process.execPath,[tool,'2','3']).toString().trim(),'5');}
else if(step==='integration'){assert.equal(cp.execFileSync(process.execPath,[built,'-2','8']).toString().trim(),'6');assert.equal(cp.spawnSync(process.execPath,[built,'bad']).status,17);}
else if(step==='benchmark_smoke'){for(let i=0;i<3;i++)assert.equal(cp.execFileSync(process.execPath,[built,'1','2']).toString().trim(),'3');}
else if(step==='failure'){console.error('intentional failure');process.exit(37);}
else throw Error('unexpected step');
console.log('tool verified '+step);
'@
        Write-Utf8File (Join-Path $toolDir 'check.cjs') $check
        Invoke-HarnessProcess git @('-C',$root,'add','small tool/sum.cjs')|Out-Null
        Invoke-HarnessProcess git @('-C',$root,'-c','core.hooksPath=','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-m','fixture')|Out-Null
        $literal="a b & c | d [x] $unicode"
        # Preflight understands executable heads without quotes; node is also on PATH.
        foreach($step in @('build','unit','integration','benchmark_smoke')){$profile.commands.$step='node '+(ShellQuote 'small tool/check.cjs')+' '+$step+' '+(ShellQuote $literal)}
        foreach($p in $profile.owners.PSObject.Properties){$p.Value.validation=$profile.commands.unit}
        SaveProfile
        foreach($step in @('build','unit','integration','benchmark_smoke')){
            Case integration "$layout configured $step builds/tests a separate real CLI tool" {
                $r=RunShell (Join-Path $engine "scripts/run_$step.sh")
                Assert-True ($r.Success -and $r.Output.Contains("tool verified $step")) $r.Output
                $row=@([IO.File]::ReadAllLines((Join-Path $root 'tool_out/calls.jsonl'))|ForEach-Object {$_|ConvertFrom-Json})[-1]
                Assert-True ($row.step -eq $step -and $row.cwd -eq $root -and $row.args[0] -ceq $literal) 'cwd or literal arguments changed'
                Assert-True (-not(Test-Path -LiteralPath (Join-Path $root 'fake_make_called'))) 'configured Node tool replaced by make'
            }
        }
        Case security "$layout unknown arguments are rejected before execution" {
            $log=Join-Path $root 'tool_out/calls.jsonl';$before=if(Test-Path -LiteralPath $log){[IO.File]::ReadAllText($log)}else{''}
            $r=RunShell (Join-Path $engine 'scripts/run_unit.sh') @('--typo','value with spaces')
            Assert-True ($r.ExitCode -eq 2) 'unknown CLI arguments silently ignored'
            $after=if(Test-Path -LiteralPath $log){[IO.File]::ReadAllText($log)}else{''};Assert-True ($before -ceq $after) 'tool ran on invalid options'
        }
        Case integration "$layout original child exit code reaches shell caller" {
            $saved=$profile.commands.unit;$profile.commands.unit='node '+(ShellQuote 'small tool/check.cjs')+' failure';SaveProfile
            try{$r=RunShell (Join-Path $engine 'scripts/run_unit.sh');Assert-True ($r.ExitCode -eq 37) ("exit code changed to "+$r.ExitCode+': '+$r.Output)}finally{$profile.commands.unit=$saved;SaveProfile}
        }
        if($BaselineOnly){continue}
        Case integration "$layout preview reports command without running tool" {
            $before=[IO.File]::ReadAllText((Join-Path $root 'tool_out/calls.jsonl'))
            $r=RunShell (Join-Path $engine 'scripts/run_unit.sh') @('--preview')
            Assert-True ($r.Success -and $r.Output.Contains('small tool/check.cjs')) $r.Output
            Assert-True ([IO.File]::ReadAllText((Join-Path $root 'tool_out/calls.jsonl')) -ceq $before) 'preview executed tool'
        }
        Case security "$layout foreign project environment cannot redirect command" {
            $env:CODEX_HARNESS_ROOT=$testRoot
            try{$r=RunShell (Join-Path $engine 'scripts/run_unit.sh');Assert-True (-not $r.Success -and $r.Output.Contains('does not match')) 'foreign root accepted'}finally{$env:CODEX_HARNESS_ROOT=$null}
            $env:CODEX_GIT_WORKSPACE_ROOT=$testRoot
            try{$r=RunShell (Join-Path $engine 'scripts/run_unit.sh');Assert-True (-not $r.Success -and $r.Output.Contains('workspace')) 'foreign workspace accepted'}finally{$env:CODEX_GIT_WORKSPACE_ROOT=$null}
        }
        Case security "$layout empty command fails without make fallback" {
            $saved=$profile.commands.unit;$profile.commands.unit='';SaveProfile
            try{$r=RunShell (Join-Path $engine 'scripts/run_unit.sh');Assert-True (-not $r.Success -and $r.Output.Contains('commands.unit')) 'empty command accepted'}finally{$profile.commands.unit=$saved;SaveProfile}
        }
        Case security "$layout command pointing back to wrapper cannot recurse" {
            $saved=$profile.commands.unit
            $profile.commands.unit='sh '+(ShellQuote ((Join-Path $engine 'scripts/run_unit.sh').Replace('\','/')));SaveProfile
            try{$r=RunShell (Join-Path $engine 'scripts/run_unit.sh');Assert-True (-not $r.Success -and $r.Output.Contains('recursive')) 'recursive entry was not rejected'}finally{$profile.commands.unit=$saved;SaveProfile}
        }
        Case integration "$layout full cycle uses the same configured commands and failure ordering" {
            $hooks=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/install_git_hooks.ps1') -AllowFailure
            Assert-True $hooks.Success $hooks.Output
            $r=RunShell (Join-Path $engine 'scripts/run_harness_cycle.sh') @('--skip-retry-prompt')
            Assert-True $r.Success $r.Output
            $log=Join-Path $root 'tool_out/calls.jsonl';$before=@([IO.File]::ReadAllLines($log)).Count
            $saved=$profile.commands.unit;$profile.commands.unit='node '+(ShellQuote 'small tool/check.cjs')+' failure';SaveProfile
            try{
                $r=RunShell (Join-Path $engine 'scripts/run_harness_cycle.sh') @('-SkipRetryPrompt')
                $rows=@([IO.File]::ReadAllLines($log)|Select-Object -Skip $before|ForEach-Object {$_|ConvertFrom-Json})
                Assert-True (-not $r.Success -and $rows.Count -eq 2 -and $rows[0].step -eq 'build' -and $rows[1].step -eq 'failure') 'cycle continued after failure'
            }finally{$profile.commands.unit=$saved;SaveProfile}
        }
        Case integration "$layout retry shell uses configured owner validation" {
            $r=RunShell (Join-Path $engine 'scripts/generate_retry_prompt.sh')
            Assert-True $r.Success $r.Output
            $files=@(Get-ChildItem -LiteralPath (Join-Path $engine 'reports/retry_prompts') -Filter '*.md' -File)
            Assert-True ($files.Count -gt 0 -and [IO.File]::ReadAllText($files[-1].FullName).Contains('small tool/check.cjs')) 'legacy make retry text retained'
        }
        Case integration "$layout relocated project validates in its new cwd" {
            $copy=Join-Path $testRoot ("relocated $layout $unicode [new]")
            # Copy-Item cannot preserve read-only Git object metadata on WSL DrvFS.
            # Let Git copy its database, then copy the installed project files.
            Invoke-HarnessProcess git @('-c','core.hooksPath=','clone','--no-hardlinks','--no-checkout',$root,$copy)|Out-Null
            foreach($item in @(Get-ChildItem -LiteralPath $root -Force|Where-Object {$_.Name -ne '.git'})){
                Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $copy $item.Name) -Recurse -Force
            }
            $copyEngine=if($layout -eq 'standalone'){$copy}else{Join-Path $copy 'harness'}
            $r=RunShell (Join-Path $copyEngine 'scripts/run_unit.sh');Assert-True $r.Success $r.Output
            $row=@([IO.File]::ReadAllLines((Join-Path $copy 'tool_out/calls.jsonl'))|ForEach-Object {$_|ConvertFrom-Json})[-1]
            Assert-True ($row.cwd -eq $copy) 'old project path retained'
        }
    }
    if(-not $BaselineOnly){
        Case integration 'quoted absolute executable and file arguments survive nested shells' {
            $saved=$profile.commands.unit
            $profile.commands.unit=(ShellQuote $node)+' '+(ShellQuote 'small tool/check.cjs')+' unit '+(ShellQuote $literal);SaveProfile
            try{$r=RunShell (Join-Path $engine 'scripts/run_unit.sh');Assert-True $r.Success $r.Output}finally{$profile.commands.unit=$saved;SaveProfile}
        }
        Case security 'cycle recursion fails before creating a cycle lock or report' {
            $env:HARNESS_VALIDATION_ACTIVE='1'
            try{$r=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/run_harness_cycle.ps1') -AllowFailure;Assert-True (-not $r.Success -and $r.Output.Contains('recursive')) 'cycle recursion accepted'}finally{$env:HARNESS_VALIDATION_ACTIVE=$null}
        }
        Case security 'missing target profile fails instead of invoking default make' {
            $empty=Join-Path $testRoot 'unconfigured project';Ensure-HarnessDirectory $empty
            Copy-Item -LiteralPath (Join-Path $source 'scripts') -Destination (Join-Path $empty 'scripts') -Recurse
            $r=RunShell (Join-Path $empty 'scripts/run_build.sh')
            Assert-True (-not $r.Success -and -not(Test-Path -LiteralPath (Join-Path $empty 'fake_make_called'))) 'unconfigured project executed make'
        }
        Case unit 'step registry refuses missing malformed and template commands' {
            $saved=$profile.commands.unit
            try{
                foreach($value in @('', 'replace-with-unit-command', @{executable='node'})){
                    $profile.commands.unit=$value;SaveProfile;$blocked=$false
                    try{Get-HarnessStepCommand $root 'unit'|Out-Null}catch{$blocked=$true}
                    Assert-True $blocked 'invalid command accepted'
                }
                $blocked=$false;try{Get-HarnessStepCommand $root '../outside'|Out-Null}catch{$blocked=$true};Assert-True $blocked 'arbitrary step accepted'
            }finally{$profile.commands.unit=$saved;SaveProfile}
        }
        Case unit 'validation rejects success no-ops and masked failure' {
            $saved=$profile.commands.unit
            try{
                foreach($value in @('echo pass','false || true')){
                    $profile.commands.unit=$value;SaveProfile;$blocked=$false
                    try{Get-HarnessStepCommand $root 'unit'|Out-Null}catch{$blocked=$true};Assert-True $blocked 'unsafe validation accepted'
                }
            }finally{$profile.commands.unit=$saved;SaveProfile}
        }
        Case unit 'command normalization retains quoted arguments exactly' {
            $command='node "small tool/check.cjs" unit "a & b [x]"'
            Assert-True ((Resolve-HarnessValidationCommand ("  "+$command+"  ")) -ceq $command) 'command arguments rewritten'
        }
        Case unit 'root resolution accepts matching environment and preserves it' {
            $env:CODEX_HARNESS_ROOT=$root;$env:CODEX_GIT_WORKSPACE_ROOT=$root
            try{Assert-True ((Get-HarnessBoundShellRoot (Join-Path $engine 'scripts')) -eq $root -and $env:CODEX_HARNESS_ROOT -eq $root) 'matching environment lost'}finally{$env:CODEX_HARNESS_ROOT=$null;$env:CODEX_GIT_WORKSPACE_ROOT=$null}
        }
        Case integration 'explicit native runtime path works without slash rewriting by caller' {
            $env:CODEX_HARNESS_PWSH=Get-HarnessPowerShellExecutable
            try{$r=RunShell (Join-Path $engine 'scripts/run_unit.sh');Assert-True $r.Success $r.Output}finally{$env:CODEX_HARNESS_PWSH=(Get-HarnessPowerShellExecutable).Replace('\','/')}
        }
        Case security 'missing explicit PowerShell does not fall back or run tool' {
            $before=[IO.File]::ReadAllText((Join-Path $root 'tool_out/calls.jsonl'))
            $missingName=if(Test-HarnessIsWindows){'missing.exe'}else{'missing-runtime'}
            $env:CODEX_HARNESS_PWSH=Join-Path $testRoot $missingName
            try{
                $r=RunShell (Join-Path $engine 'scripts/run_unit.sh')
                Assert-True (-not $r.Success -and $r.Output.Contains('not executable')) 'runtime fallback occurred'
                if($env:WSL_DISTRO_NAME){
                    $env:CODEX_HARNESS_PWSH=Join-Path $testRoot 'windows-runtime.exe'
                    $r=RunShell (Join-Path $engine 'scripts/run_unit.sh')
                    Assert-True (-not $r.Success -and $r.Output.Contains('Windows runtime refused')) 'WSL accepted a Windows runtime'
                }
                Assert-True ([IO.File]::ReadAllText((Join-Path $root 'tool_out/calls.jsonl')) -ceq $before) 'runtime failure executed tool'
            }finally{$env:CODEX_HARNESS_PWSH=(Get-HarnessPowerShellExecutable).Replace('\','/')}
        }
        Case security 'bridge refuses arbitrary entry point and help is side effect free' {
            $r=RunShell (Join-Path $engine 'scripts/invoke_harness.sh') @('../../evil');Assert-True ($r.ExitCode -eq 2) 'arbitrary script allowed'
            $r=RunShell (Join-Path $engine 'scripts/run_unit.sh') @('--help');Assert-True ($r.Success -and $r.Output.Contains('--preview')) 'help unavailable'
        }
    }
}finally{$env:PATH=$oldPath;$env:CODEX_HARNESS_PWSH=$oldPs;$env:CODEX_HARNESS_ROOT=$oldRoot;$env:CODEX_GIT_WORKSPACE_ROOT=$oldWorkspace;$env:HARNESS_VALIDATION_ACTIVE=$oldActive;$env:HARNESS_CI_MODE=$oldCi;$env:HARNESS_NOTIFY_DISABLED=$oldNotify}
Write-Utf8File (Join-Path $testRoot 'results.json') ($results.ToArray()|ConvertTo-Json -Depth 8)
$failed=@($results|Where-Object{-not $_.passed}).Count
Write-Output "Shell results: $($results.Count-$failed)/$($results.Count) passed; artifacts: $testRoot"
if($failed -or $results.Count -eq 0){exit 1}
