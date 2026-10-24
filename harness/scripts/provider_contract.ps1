# Fixed provider registry. Never load an adapter path or function from profile/log data.
function Assert-HarnessProviderContract($Contract) {
    if($null -eq $Contract -or -not (Test-HarnessUsageInteger $Contract.version) -or $Contract.version -ne 1 -or $Contract.provider -cnotin @('codex','claude')) {throw 'unsupported provider contract; execution refused'}
    foreach($field in $Contract.PSObject.Properties.Name){if($field -cnotin @('version','provider','requested_model')){throw 'unknown provider contract field'}}
    if($null -ne $Contract.requested_model -and $Contract.requested_model -isnot [string]){throw 'invalid requested model in provider contract'}
}

function Get-HarnessConfiguredProvider([string]$RootDir) {
    $profile=[IO.File]::ReadAllText((Get-ProjectProfilePath $RootDir))|ConvertFrom-Json
    $selection=$profile.PSObject.Properties['worker_provider']
    if($null -eq $selection){return 'codex'}
    $value=$selection.Value
    if($null -eq $value -or -not (Test-HarnessUsageInteger $value.version) -or $value.version -ne 1 -or $value.name -cnotin @('codex','claude')){throw 'unsupported worker_provider configuration; no fallback attempted'}
    foreach($field in $value.PSObject.Properties.Name){if($field -cnotin @('version','name')){throw 'unknown worker_provider configuration field'}}
    return $value.name
}

function Get-HarnessWorkerProviderContract($WorkerRecord) {
    $property=$WorkerRecord.PSObject.Properties['provider_contract']
    if($null -ne $property){Assert-HarnessProviderContract $property.Value;return $property.Value}
    # Only records from the historically Codex-only engine use this compatibility path.
    return [pscustomobject]@{version=1;provider='codex';requested_model=(Get-CodexRequestedModel @($WorkerRecord.arguments))}
}

function New-HarnessProviderLaunch([string]$Provider,[string]$Workspace,[string]$LastMessageFile,[string]$Model,[switch]$Ephemeral) {
    $contract=[pscustomobject]@{version=1;provider=$Provider;requested_model=$(if(-not [string]::IsNullOrWhiteSpace($Model)){$Model}else{$null})}
    Assert-HarnessProviderContract $contract
    $launch=if($Provider -ceq 'claude'){New-ClaudeProviderLaunch $Model -Ephemeral:$Ephemeral}else{New-CodexProviderLaunch $Workspace $LastMessageFile $Model -Ephemeral:$Ephemeral}
    return [pscustomobject]@{contract=$contract;executable=$launch.executable;arguments=$launch.arguments;input_mode='stdin';output_mode='jsonl'}
}

function Get-HarnessProviderVersion($Launch) {
    Assert-HarnessProviderContract $Launch.contract
    if($Launch.contract.provider -ceq 'claude'){return Get-ClaudeProviderVersion $Launch.executable}
    return Get-CodexProviderVersion $Launch.executable
}

function Get-HarnessProviderErrorKind([string]$Provider,[string]$ResponseStatus,[int]$ExitCode) {
    if($ExitCode -ne 0){return 'process_exit'}
    if($ResponseStatus -ceq 'failed'){return 'provider_error'}
    if($Provider -ceq 'claude' -and $ResponseStatus -cne 'completed'){return 'provider_protocol'}
    return 'none'
}

function Export-HarnessProviderLastMessage($WorkerRecord,[string]$LogPath,[string]$OutputPath) {
    $contract=Get-HarnessWorkerProviderContract $WorkerRecord
    if($contract.provider -ceq 'claude'){
        $parsed=Get-ClaudeOutputFromLog $LogPath $WorkerRecord.exit_code
        Write-Utf8File $OutputPath $parsed.message
    }
}

function Get-HarnessProviderResult($WorkerRecord,[string]$LogPath,[int]$ExitCode) {
    $contract=Get-HarnessWorkerProviderContract $WorkerRecord
    if($contract.provider -ceq 'claude'){
        $parsed=Get-ClaudeOutputFromLog $LogPath $ExitCode;$protocol=$parsed.response_status;$usage=$parsed.usage
    }else{$protocol=Get-CodexResponseStatus $LogPath;$usage=Get-CodexUsageFromLog $LogPath $ExitCode}
    $errorKind=Get-HarnessProviderErrorKind $contract.provider $protocol $ExitCode
    return [pscustomobject]@{
        version=1;provider=$contract.provider;invocation_id=$WorkerRecord.invocation_id;exit_code=$ExitCode
        execution_status=$(if($errorKind -cne 'none'){'failed'}else{'succeeded'})
        response_status=$protocol;error_kind=$errorKind
        requested_model=$contract.requested_model;resolved_model=$null;usage=$usage
    }
}

function Assert-HarnessProviderResult($Result,$Contract,[string]$InvocationId,$ExitCode) {
    Assert-HarnessProviderContract $Contract
    if($null -eq $Result -or -not (Test-HarnessUsageInteger $Result.version) -or $Result.version -ne 1 -or $Result.provider -cne $Contract.provider -or
        $Result.invocation_id -cne $InvocationId -or ($Result.exit_code -isnot [int] -and $Result.exit_code -isnot [long]) -or $Result.exit_code -ne $ExitCode -or
        $Result.requested_model -cne $Contract.requested_model -or $Result.execution_status -cnotin @('succeeded','failed') -or
        $Result.response_status -cnotin @('completed','failed','unknown')) {throw 'invalid or mismatched provider result'}
    $errorKind=Get-HarnessProviderErrorKind $Contract.provider $Result.response_status $ExitCode
    $expected=if($errorKind -cne 'none'){'failed'}else{'succeeded'}
    if($Result.execution_status -cne $expected -or $Result.error_kind -cne $errorKind -or $Result.usage.status -cnotin @('known','unknown')){throw 'inconsistent provider result'}
    if($Result.usage.status -ceq 'known'){
        foreach($name in @('input_tokens','cached_input_tokens','output_tokens')){if(-not (Test-HarnessUsageInteger $Result.usage.$name)){throw 'invalid provider token count'}}
        if($Result.usage.cached_input_tokens -gt $Result.usage.input_tokens -or $expected -eq 'failed'){throw 'inconsistent provider usage'}
    }else{
        foreach($name in @('input_tokens','cached_input_tokens','output_tokens')){if($null -ne $Result.usage.$name){throw 'unknown provider usage must contain null counts'}}
    }
}

function Assert-HarnessWorkerProviderSuccess($WorkerRecord) {
    $contract=Get-HarnessWorkerProviderContract $WorkerRecord
    if($null -ne $WorkerRecord.PSObject.Properties['provider_contract']){
        Assert-HarnessProviderResult $WorkerRecord.provider_result $contract $WorkerRecord.invocation_id $WorkerRecord.exit_code
        if($WorkerRecord.provider_result.execution_status -cne 'succeeded'){throw 'provider reported execution failure'}
    }
}
