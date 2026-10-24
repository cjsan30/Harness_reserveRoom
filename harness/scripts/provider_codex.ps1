function Get-CodexUsageFromLog([string]$LogPath, [int]$ExitCode) {
    $totals = @{ input_tokens=[long]0; cached_input_tokens=[long]0; output_tokens=[long]0 }
    $turns=0; $active=$false; $invalid=($ExitCode -ne 0)
    # Stream rather than loading an entire command-output log into memory.
    foreach ($line in [IO.File]::ReadLines($LogPath)) {
        if (-not $line.TrimStart().StartsWith('{')) { continue }
        try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { $invalid=$true; continue }
        if ($event.type -ceq 'turn.started') {
            if ($active) { $invalid=$true }
            $active=$true
        } elseif ($event.type -ceq 'turn.completed') {
            if (-not $active) { $invalid=$true }
            $active=$false
            $valid=$true
            foreach ($name in @('input_tokens','cached_input_tokens','output_tokens')) {
                if (-not (Test-HarnessUsageInteger $event.usage.$name)) { $valid=$false }
            }
            if ($valid -and $event.usage.cached_input_tokens -gt $event.usage.input_tokens) { $valid=$false }
            if (-not $valid) { $invalid=$true; continue }
            foreach ($name in @('input_tokens','cached_input_tokens','output_tokens')) {
                # Decimal intermediate detects overflow without wrapping or rounding.
                $sum=[decimal]$totals[$name]+[decimal]$event.usage.$name
                if ($sum -gt [long]::MaxValue) { $invalid=$true } else { $totals[$name]=[long]$sum }
            }
            $turns++
        } elseif ($event.type -cin @('turn.failed','error')) { $invalid=$true }
    }
    $known=($turns -gt 0 -and -not $active -and -not $invalid)
    return [pscustomobject]@{
        status=$(if($known){'known'}else{'unknown'}); completed_turns=$turns
        input_tokens=$(if($known){$totals.input_tokens}else{$null})
        cached_input_tokens=$(if($known){$totals.cached_input_tokens}else{$null})
        output_tokens=$(if($known){$totals.output_tokens}else{$null})
        source='codex.exec.jsonl'
    }
}

function New-CodexProviderLaunch([string]$Workspace,[string]$LastMessageFile,[string]$Model,[switch]$Ephemeral) {
    $name=if($env:HARNESS_CODEX_PATH){$env:HARNESS_CODEX_PATH}else{'codex'}
    $command=Get-Command $name -ErrorAction SilentlyContinue
    if($null -eq $command -or $command.CommandType -notin @('Application','ExternalScript')){throw 'Codex provider executable is unavailable; no fallback attempted'}
    $arguments=@('exec','--sandbox','workspace-write','--json','--skip-git-repo-check','--color','never')
    if($Ephemeral){$arguments+='--ephemeral'}
    if(-not [string]::IsNullOrWhiteSpace($Model)){$arguments+=@('-m',$Model)}
    $arguments+=@('-C',$Workspace,'-o',$LastMessageFile,'-')
    return [pscustomobject]@{executable=$command.Source;arguments=$arguments}
}

function Get-CodexProviderVersion([string]$Executable) {
    try {$r=Invoke-HarnessProcess $Executable @('--version') -AllowFailure;if($r.Success -and $r.Output){return $r.Output}}catch{}
    return 'unknown'
}

function Get-CodexRequestedModel($Arguments) {
    $model=$null
    for($i=0;$i -lt $Arguments.Count-1;$i++){if($Arguments[$i] -ceq '-m'){$model=$Arguments[$i+1]}}
    return $model
}

function Get-CodexResponseStatus([string]$LogPath) {
    $completed=$false;$failed=$false;$active=$false;$invalid=$false
    foreach($line in [IO.File]::ReadLines($LogPath)){
        if(-not $line.TrimStart().StartsWith('{')){continue}
        try{$event=$line|ConvertFrom-Json -ErrorAction Stop}catch{$invalid=$true;continue}
        switch -CaseSensitive ($event.type){
            'turn.started' {if($active){$invalid=$true};$active=$true}
            'turn.completed' {if(-not $active){$invalid=$true};$active=$false;$completed=$true}
            'turn.failed' {$failed=$true}
            'error' {$failed=$true}
        }
    }
    if($failed){return 'failed'}
    if($completed -and -not $active -and -not $invalid){return 'completed'}
    return 'unknown'
}

