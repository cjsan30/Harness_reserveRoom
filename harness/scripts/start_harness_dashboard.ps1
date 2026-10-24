param(
    [ValidateRange(0,65535)][int]$Port=0,
    [ValidateRange(5,300)][int]$RefreshSeconds=10,
    [string]$PythonExecutable='',
    [switch]$NoOpen
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$root=Get-HarnessRoot $PSScriptRoot
if(-not $PythonExecutable){
    foreach($name in @('python3','python')){
        $candidate=Get-Command $name -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
        if($candidate){$PythonExecutable=$candidate.Source;break}
    }
}
if(-not $PythonExecutable){throw 'Dashboard requires Python 3.9+. Supply -PythonExecutable with its executable path.'}
$arguments=@('-B',(Join-Path $PSScriptRoot 'harness_dashboard_server.py'),'--root',$root,'--powershell',(Get-HarnessPowerShellExecutable),'--port',[string]$Port,'--refresh',[string]$RefreshSeconds)
if(-not $NoOpen){$arguments+='--open'}
# Direct argv forwarding preserves paths and streams the URL immediately.
& $PythonExecutable @arguments
exit $LASTEXITCODE
