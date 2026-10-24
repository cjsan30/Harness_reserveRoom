# Claude Code print-mode adapter. No authentication, installation or paid probe here.
function New-ClaudeProviderLaunch([string]$Model,[switch]$Ephemeral) {
    $name=if($env:HARNESS_CLAUDE_PATH){$env:HARNESS_CLAUDE_PATH}else{'claude'}
    $command=Get-Command $name -ErrorAction SilentlyContinue
    if($null -eq $command -or $command.CommandType -notin @('Application','ExternalScript')){throw 'Claude provider executable is unavailable; no fallback attempted'}
    # Preserve operator/managed permission rules. Never grant unrestricted Bash or bypass permissions.
    $arguments=@('--print','--input-format','text','--output-format','stream-json','--verbose','--permission-mode','acceptEdits','--permission-prompts','none')
    if($Ephemeral){$arguments+='--no-session-persistence'}
    if(-not [string]::IsNullOrWhiteSpace($Model)){$arguments+=@('--model',$Model)}
    return [pscustomobject]@{executable=$command.Source;arguments=$arguments}
}

function Get-ClaudeProviderVersion([string]$Executable) {
    try{$r=Invoke-HarnessProcess $Executable @('--version') -AllowFailure;if($r.Success -and $r.Output){return $r.Output}}catch{}
    return 'unknown'
}

function Get-ClaudeOutputFromLog([string]$LogPath,[int]$ExitCode) {
    $terminal=$null;$count=0;$failed=$false;$invalid=$false;$session=$null
    foreach($line in [IO.File]::ReadLines($LogPath)){
        if(-not $line.TrimStart().StartsWith('{')){continue}
        try{$event=$line|ConvertFrom-Json -ErrorAction Stop}catch{$invalid=$true;continue}
        if($event -isnot [pscustomobject] -or $event.type -isnot [string]){$invalid=$true;continue}
        if($event.type -ceq 'error' -or ($event.type -ceq 'system' -and $event.subtype -ceq 'permission_denied')){$failed=$true}
        if($event.type -ceq 'system' -and $event.subtype -ceq 'init'){
            if($count -gt 0 -or $null -ne $session){$invalid=$true}
            $session=$event.session_id
        }
        if($event.type -cne 'result'){continue}
        $count++;$terminal=$event
        if($event.is_error -is [bool] -and $event.is_error){$failed=$true}
        if($event.subtype -is [string] -and $event.subtype.StartsWith('error_',[StringComparison]::Ordinal)){$failed=$true}
        if($null -ne $event.permission_denials -and @($event.permission_denials).Count -gt 0){$failed=$true}
        if($null -ne $event.errors -and @($event.errors).Count -gt 0){$failed=$true}
        if($null -ne $event.terminal_reason -and $event.terminal_reason -cne 'completed'){$failed=$true}
        if($event.is_error -isnot [bool] -or $event.subtype -isnot [string] -or $event.subtype -cne 'success'){$invalid=$true}
        if($null -ne $session -and $event.session_id -cne $session){$invalid=$true}
    }
    $response=if($failed){'failed'}elseif($count -eq 1 -and -not $invalid){'completed'}else{'unknown'}
    $known=($response -ceq 'completed' -and $ExitCode -eq 0)
    foreach($name in @('input_tokens','cache_read_input_tokens','cache_creation_input_tokens','output_tokens')){
        if(-not (Test-HarnessUsageInteger $terminal.usage.$name)){$known=$false}
    }
    $total=[decimal]0
    if($known){
        $total=[decimal]$terminal.usage.input_tokens+[decimal]$terminal.usage.cache_read_input_tokens+[decimal]$terminal.usage.cache_creation_input_tokens
        if($total -gt [long]::MaxValue){$known=$false}
    }
    # Consume only the invocation result aggregate, never assistant/delta/modelUsage totals again.
    $usage=[pscustomobject]@{
        status=$(if($known){'known'}else{'unknown'});completed_turns=$(if($response -ceq 'completed'){1}else{0})
        input_tokens=$(if($known){[long]$total}else{$null})
        cached_input_tokens=$(if($known){$terminal.usage.cache_read_input_tokens}else{$null})
        output_tokens=$(if($known){$terminal.usage.output_tokens}else{$null})
        source='claude.print.stream-json'
    }
    return [pscustomobject]@{
        response_status=$response;usage=$usage
        message=$(if($response -ceq 'completed' -and $ExitCode -eq 0 -and $terminal.result -is [string]){$terminal.result}else{''})
    }
}
