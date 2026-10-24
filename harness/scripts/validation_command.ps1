# Shared by the cycle and single-step shell entry points.
function Assert-HarnessValidationNotRecursive {
    if(-not [string]::IsNullOrWhiteSpace($env:HARNESS_VALIDATION_ACTIVE)){
        throw 'recursive Harness validation refused; configure the underlying project tool instead of a Harness wrapper'
    }
}

function Resolve-HarnessValidationCommand([string]$Command) {
    $trimmed=$Command.Trim()
    if($trimmed -match '^make(?=\s|$)'){
        $make=$null
        foreach($name in @('make','mingw32-make')){
            $candidate=Get-Command $name -ErrorAction SilentlyContinue
            if($null -ne $candidate -and $candidate.CommandType -eq 'Application'){$make=$candidate.Source;break}
        }
        if($null -eq $make){throw 'no make-compatible command found for configured command'}
        $quoted=if(Test-HarnessIsWindows){'"'+$make+'"'}else{"'"+$make.Replace("'","'\''")+"'"}
        return $quoted+$trimmed.Substring(4)
    }
    return $trimmed
}

function Get-HarnessStepCommand([string]$RootDir,[string]$Step) {
    if($Step -cnotin @('build','unit','integration','benchmark_smoke')){throw 'unsupported validation step'}
    $profile=Get-ProjectProfile $RootDir
    $command=Get-ProjectObjectProperty (Get-ProjectObjectProperty $profile 'commands') $Step
    if($command -isnot [string] -or [string]::IsNullOrWhiteSpace($command) -or $command -match '^replace-with-'){
        throw "commands.$Step is missing or not configured; no make fallback attempted"
    }
    $issues=@(Get-HarnessValidationCommandIssues $command)
    if($issues.Count){throw ("commands.$Step is unsafe: "+($issues -join '; '))}
    return Resolve-HarnessValidationCommand $command
}

function Invoke-HarnessValidationCommand([string]$RootDir,[string]$Command) {
    Assert-HarnessValidationNotRecursive
    $previous=$env:HARNESS_VALIDATION_ACTIVE
    try{
        $env:HARNESS_VALIDATION_ACTIVE='1'
        return Invoke-HarnessShellCommand -RootDir $RootDir -CommandText $Command -AllowFailure
    }finally{$env:HARNESS_VALIDATION_ACTIVE=$previous}
}

function Get-HarnessBoundShellRoot([string]$ScriptDirectory) {
    $override=$env:CODEX_HARNESS_ROOT
    try{$env:CODEX_HARNESS_ROOT=$null;$root=Get-HarnessRoot $ScriptDirectory}finally{$env:CODEX_HARNESS_ROOT=$override}
    $comparison=Get-HarnessPathComparison
    if(-not [string]::IsNullOrWhiteSpace($override) -and -not [string]::Equals([IO.Path]::GetFullPath($override).TrimEnd([IO.Path]::DirectorySeparatorChar),$root.TrimEnd([IO.Path]::DirectorySeparatorChar),$comparison)){
        throw 'CODEX_HARNESS_ROOT does not match this installed shell entry; refusing cross-project execution'
    }
    if(-not [string]::Equals((Get-HarnessEngineRoot $root),(Split-Path -Parent $ScriptDirectory),$comparison)){throw 'shell engine does not match target layout'}
    # Shell validation targets the installed project. Never silently validate the
    # main checkout when a caller expects a different inherited worktree.
    $workspace=$env:CODEX_GIT_WORKSPACE_ROOT
    if(-not [string]::IsNullOrWhiteSpace($workspace) -and -not [string]::Equals([IO.Path]::GetFullPath($workspace).TrimEnd([IO.Path]::DirectorySeparatorChar),$root.TrimEnd([IO.Path]::DirectorySeparatorChar),$comparison)){
        throw 'inherited workspace differs from this installed shell entry; run the entry installed in the intended workspace with matching environment'
    }
    return $root
}
