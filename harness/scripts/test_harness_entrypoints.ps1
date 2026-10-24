param([string]$FixtureDirectory='', [string]$OutputDirectory='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$source=Split-Path -Parent $PSScriptRoot
if(-not $OutputDirectory){$OutputDirectory=Join-Path $source '.test-output'}
$testRoot=Join-Path $OutputDirectory ([Guid]::NewGuid().ToString('N'));Ensure-HarnessDirectory $testRoot
$results=New-Object 'System.Collections.Generic.List[object]'
function Assert-True($Value,[string]$Message){if(-not $Value){throw $Message}}
function Case([string]$Kind,[string]$Name,[scriptblock]$Body){
    try{& $Body;$results.Add(@{kind=$Kind;name=$Name;passed=$true});Write-Output "PASS [$Kind] $Name"}
    catch{$results.Add(@{kind=$Kind;name=$Name;passed=$false;error=$_.Exception.Message});Write-Output "FAIL [$Kind] $Name : $($_.Exception.Message)"}
}
function Quote-Posix([string]$Value){return "'"+$Value.Replace("'","'\''")+"'"}
function Read-Calls {return @([IO.File]::ReadAllLines((Join-Path $root 'tool_out/calls.jsonl'))|ForEach-Object {$_|ConvertFrom-Json})}
function Save-Profile {Write-Utf8File $profilePath ($profile|ConvertTo-Json -Depth 20)}
$runtime=Get-HarnessPowerShellExecutable
$git=(Get-Command git).Source
$bash=if(Test-HarnessIsWindows){Join-Path (Split-Path -Parent (Split-Path -Parent $git)) 'bin/bash.exe'}else{(Get-Command bash -ErrorAction Stop).Source}
$routes=@('PowerShell','Bash');if(Test-HarnessIsWindows){$routes+= 'CMD'}
$oldPath=$env:PATH;$oldPs=$env:CODEX_HARNESS_PWSH;$oldRoot=$env:CODEX_HARNESS_ROOT;$oldWorkspace=$env:CODEX_GIT_WORKSPACE_ROOT
$oldCi=$env:HARNESS_CI_MODE;$oldNotify=$env:HARNESS_NOTIFY_DISABLED;$oldActive=$env:HARNESS_VALIDATION_ACTIVE
function Run-Entry([string]$Route,[string]$PsFile,[string[]]$PsArgs,[string]$ShFile='',[string[]]$ShArgs=@()){
    if($Route -eq 'Bash'){
        if($ShFile){return Invoke-HarnessProcess $bash (@('--noprofile','--norc',$ShFile.Replace('\','/'))+$ShArgs) -WorkingDirectory $testRoot -AllowFailure}
        $runner=Join-Path $testRoot 'public-cli.sh'
        $tokens=@($runtime.Replace('\','/'),'-NoProfile','-File',$PsFile.Replace('\','/'))+$PsArgs
        $line=(@($tokens|ForEach-Object {Quote-Posix $_}) -join ' ')
        Write-Utf8File $runner ("#!/bin/sh`nexport MSYS2_ARG_CONV_EXCL='*'`nexec "+$line+"`n")
        return Invoke-HarnessProcess $bash @('--noprofile','--norc',$runner.Replace('\','/')) -WorkingDirectory $testRoot -AllowFailure
    }
    $tokens=@('-NoProfile');if(Test-HarnessIsWindows){$tokens+=@('-ExecutionPolicy','Bypass')};$tokens+=@('-File',$PsFile)+$PsArgs
    if($Route -eq 'CMD'){
        # Known test paths/options only; use the real cmd command parser.
        $line=(@((@($runtime)+$tokens)|ForEach-Object {'"'+$_+'"'}) -join ' ')
        return Invoke-HarnessProcess $env:ComSpec @('/d','/s','/c',$line) -WorkingDirectory $testRoot -AllowFailure
    }
    return Invoke-HarnessProcess $runtime $tokens -WorkingDirectory $testRoot -AllowFailure
}
try{
    $env:CODEX_HARNESS_ROOT=$null;$env:CODEX_GIT_WORKSPACE_ROOT=$null;$env:HARNESS_VALIDATION_ACTIVE=$null
    $env:CODEX_HARNESS_PWSH=$runtime;$env:HARNESS_CI_MODE='true';$env:HARNESS_NOTIFY_DISABLED='1'
    $env:PATH=(Split-Path -Parent $bash)+[IO.Path]::PathSeparator+$oldPath
    if(-not $FixtureDirectory){
        $seed=Invoke-HarnessPowerShellFile (Join-Path $PSScriptRoot 'test_harness_shell.ps1') @('-OutputDirectory',$OutputDirectory) -AllowFailure
        if(-not $seed.Success){throw $seed.Output}
        Write-Output $seed.Output
        $match=[regex]::Match($seed.Output,'Shell results: 36/36 passed; artifacts: ([^\r\n]+)')
        if(-not $match.Success){throw 'shell fixture result missing'}
        $FixtureDirectory=$match.Groups[1].Value
    }
    $FixtureDirectory=[IO.Path]::GetFullPath($FixtureDirectory)
    $unicode=[string][char]0xD55C+[char]0xAE00
    foreach($layout in @('standalone','nested')){
        $root=Join-Path $FixtureDirectory ("$layout $unicode [safe] & project")
        $engine=if($layout -eq 'standalone'){$root}else{Join-Path $root 'harness'}
        $profilePath=Join-Path $engine 'project/configs/project_profile.json'
        $profile=[IO.File]::ReadAllText($profilePath)|ConvertFrom-Json
        $entry=Join-Path $engine 'scripts/run_harness_shell.ps1'
        foreach($route in $routes){
            Case integration "$layout $route actual tool cwd and literal arguments" {
                $r=Run-Entry $route $entry @('-Action','unit') (Join-Path $engine 'scripts/run_unit.sh')
                Assert-True $r.Success $r.Output
                $row=(Read-Calls)[-1]
                Assert-True ($row.cwd -eq $root -and $row.step -eq 'unit' -and $row.args[0] -ceq "a b & c | d [x] $unicode") 'cwd or arguments changed'
            }
            Case integration "$layout $route preview does not execute tool" {
                $before=(Read-Calls).Count
                $r=Run-Entry $route $entry @('-Action','unit','-Preview') (Join-Path $engine 'scripts/run_unit.sh') @('--preview')
                Assert-True $r.Success $r.Output
                $j=$r.Output|ConvertFrom-Json
                Assert-True ($j.root -eq $root -and $j.executes -eq $false -and (Read-Calls).Count -eq $before) 'preview executed or targeted wrong project'
            }
            Case integration "$layout $route child exit 37 is preserved" {
                $saved=$profile.commands.unit
                $profile.commands.unit='node "small tool/check.cjs" failure';Save-Profile
                try{$r=Run-Entry $route $entry @('-Action','unit') (Join-Path $engine 'scripts/run_unit.sh');Assert-True ($r.ExitCode -eq 37) $r.Output}finally{$profile.commands.unit=$saved;Save-Profile}
            }
            Case security "$layout $route public CLI rejects unknown option" {
                $r=Run-Entry $route (Join-Path $engine 'scripts/harness.ps1') @('status','-Root',$root,'-Typo','-Json')
                Assert-True ($r.ExitCode -eq 2) $r.Output
                $j=$r.Output|ConvertFrom-Json;Assert-True ($j.exit_code -eq 2) 'invalid CLI response'
            }
            Case integration "$layout $route full cycle success and failure stop" {
                $before=(Read-Calls).Count
                $r=Run-Entry $route (Join-Path $engine 'scripts/run_harness_cycle.ps1') @('-SkipRetryPrompt') (Join-Path $engine 'scripts/run_harness_cycle.sh') @('--skip-retry-prompt')
                Assert-True $r.Success $r.Output
                $rows=@(Read-Calls|Select-Object -Skip $before)
                Assert-True (($rows.step -join ',') -ceq 'build,unit,integration,benchmark_smoke') 'cycle order changed'
                $before=(Read-Calls).Count;$saved=$profile.commands.unit
                $profile.commands.unit='node "small tool/check.cjs" failure';Save-Profile
                try{
                    $r=Run-Entry $route (Join-Path $engine 'scripts/run_harness_cycle.ps1') @('-SkipRetryPrompt') (Join-Path $engine 'scripts/run_harness_cycle.sh') @('--skip-retry-prompt')
                    $rows=@(Read-Calls|Select-Object -Skip $before)
                    Assert-True ($r.ExitCode -eq 1 -and ($rows.step -join ',') -ceq 'build,failure') 'cycle continued or hid failure'
                }finally{$profile.commands.unit=$saved;Save-Profile}
            }
        }
    }
}finally{
    $env:PATH=$oldPath;$env:CODEX_HARNESS_PWSH=$oldPs;$env:CODEX_HARNESS_ROOT=$oldRoot;$env:CODEX_GIT_WORKSPACE_ROOT=$oldWorkspace
    $env:HARNESS_CI_MODE=$oldCi;$env:HARNESS_NOTIFY_DISABLED=$oldNotify;$env:HARNESS_VALIDATION_ACTIVE=$oldActive
    Write-Utf8File (Join-Path $testRoot 'results.json') ($results.ToArray()|ConvertTo-Json -Depth 8)
    Write-Utf8File (Join-Path $testRoot 'environment.json') (@{runtime=$runtime;version=$PSVersionTable.PSVersion.ToString();os=[Environment]::OSVersion.VersionString;bash=$bash;fixture=$FixtureDirectory;routes=$routes}|ConvertTo-Json -Depth 5)
}
$failed=@($results|Where-Object {-not $_.passed}).Count
Write-Output "Entrypoint results: $($results.Count-$failed)/$($results.Count) passed; artifacts: $testRoot"
if($failed){exit 1}
