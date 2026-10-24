[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('build','unit','integration','benchmark_smoke','cycle','retry')][string]$Action,
    [switch]$Preview,
    [switch]$SkipRetryPrompt
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
try{
    if($SkipRetryPrompt -and $Action -ne 'cycle'){throw 'SkipRetryPrompt is only valid for cycle'}
    if($Preview -and $Action -in @('cycle','retry')){throw 'Preview is only supported for individual validation steps'}
    Assert-HarnessValidationNotRecursive
    $root=Get-HarnessBoundShellRoot $PSScriptRoot
    if($Action -eq 'cycle'){
        $childArgs=@();if($SkipRetryPrompt){$childArgs+='-SkipRetryPrompt'}
        $r=Invoke-HarnessPowerShellFile (Join-Path $PSScriptRoot 'run_harness_cycle.ps1') $childArgs -AllowFailure
    }elseif($Action -eq 'retry'){
        $r=Invoke-HarnessPowerShellFile (Join-Path $PSScriptRoot 'generate_retry_prompt.ps1') -AllowFailure
    }else{
        $command=Get-HarnessStepCommand $root $Action
        if($Preview){[pscustomobject]@{action=$Action;root=$root;command=$command;executes=$false}|ConvertTo-Json;exit 0}
        $r=Invoke-HarnessValidationCommand $root $command
    }
    if($r.Output){Write-Output $r.Output}
    exit $r.ExitCode
}catch{[Console]::Error.WriteLine($_.Exception.Message);exit 1}
