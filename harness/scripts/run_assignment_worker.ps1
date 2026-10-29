param(
    [Parameter(Mandatory=$true)][string]$RootDir,
    [Parameter(Mandatory=$true)][string]$AssignmentId,
    [Parameter(Mandatory=$true)][string]$InvocationId
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$paths = Get-AssignmentWorkerPaths $RootDir $AssignmentId
$lease = Acquire-HarnessLock $paths.LockRoot ('worker_' + $AssignmentId)
if ($null -eq $lease) { throw 'worker lease is already held' }
try {
    $record = Get-AssignmentWorkerRecord $RootDir $AssignmentId
    if ($null -eq $record -or $record.invocation_id -cne $InvocationId -or $record.status -cne 'starting') { throw 'worker launch intent is not current' }
    $null=Get-HarnessWorkerProviderContract $record
    $record.status = 'running'
    $record.worker_pid = $PID
    $record.worker_started_at = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    $nativeIdentity=Get-HarnessLinuxProcessIdentity $PID
    if($nativeIdentity){$record|Add-Member -NotePropertyName worker_process_identity -NotePropertyValue $nativeIdentity -Force}
    Write-Utf8File $paths.Record ($record | ConvertTo-Json -Depth 8)
    $promptFile = Resolve-ProjectPath $RootDir $record.prompt_file 'worker prompt'
    $logFile = Resolve-ProjectPath $RootDir $record.log_file 'worker log'
    $executionRoot = Resolve-ProjectPath $RootDir $record.execution_root 'worker workspace' -AllowProjectRoot
    $env:CODEX_HARNESS_ROOT = $RootDir
    $env:CODEX_GIT_WORKSPACE_ROOT = $executionRoot
    $env:HARNESS_INVOCATION_ID = $InvocationId
    $env:HARNESS_ASSIGNMENT_ID = $AssignmentId
    Write-Utf8File $logFile ''
    $prompt = [IO.File]::ReadAllText($promptFile)
    $executable = $record.executable
    if ($null -eq (Get-Command $executable -ErrorAction SilentlyContinue)) { throw 'recorded worker executable is unavailable' }
    $workerArguments = @($record.arguments)
    # Per-invocation wall-clock limit. The watchdog stops only the provider tree;
    # this host survives to record a confirmed exit.
    $timeoutSeconds = $null
    if ($null -ne $record.PSObject.Properties['timeout_seconds']) { $timeoutSeconds = $record.timeout_seconds }
    $timeoutMarker = $paths.Record + '.timeout'
    $doneMarker = $paths.Record + '.done'
    foreach ($marker in @($timeoutMarker, $doneMarker)) { if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force } }
    $watchdog = $null
    if ($null -ne $timeoutSeconds) {
        $watchdogArguments = @('-NoProfile')
        if (Test-HarnessIsWindows) { $watchdogArguments += @('-ExecutionPolicy', 'Bypass') }
        $watchdogArguments += @('-File', (Join-Path $PSScriptRoot 'worker_timeout_watchdog.ps1'), '-HostPid', [string]$PID, '-HostStartedAt', $record.worker_started_at, '-TimeoutSeconds', [string]$timeoutSeconds, '-TimeoutMarker', $timeoutMarker, '-DoneMarker', $doneMarker)
        if ($null -ne $record.PSObject.Properties['worker_process_identity'] -and -not [string]::IsNullOrWhiteSpace($record.worker_process_identity)) {
            $watchdogArguments += @('-HostIdentity', [string]$record.worker_process_identity)
        }
        # ProcessStartInfo, not Start-Process: a working directory with [ ] would be
        # treated as a wildcard, and inherited std handles would hold the parent's pipe.
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = Get-HarnessPowerShellExecutable
        $startInfo.Arguments = ($watchdogArguments | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' '
        $startInfo.WorkingDirectory = $PSScriptRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $watchdog = [Diagnostics.Process]::Start($startInfo)
        $watchdog.StandardInput.Close()
    }
    $duration = [Diagnostics.Stopwatch]::StartNew()
    $previousOutputEncoding=$OutputEncoding
    $previousConsoleEncoding=[Console]::OutputEncoding
    Push-Location -LiteralPath $executionRoot
    try {
        # Stream to the log here so a dead parent cannot cause a broken output pipe.
        $ErrorActionPreference = 'Continue'
        $OutputEncoding=New-Object System.Text.UTF8Encoding($false)
        [Console]::OutputEncoding=$OutputEncoding
        $global:LASTEXITCODE = 0
        # The last output time tells a hung command apart from a worker still busy at timeout.
        $lastOutputAt = [DateTime]::UtcNow
        $prompt | & $executable @workerArguments 2>&1 | ForEach-Object { $lastOutputAt = [DateTime]::UtcNow; Append-Utf8File $logFile (Protect-HarnessSecretText $_.ToString()) -ErrorAction Stop }
        $code = $LASTEXITCODE
        $idleSecondsAtExit = ([DateTime]::UtcNow - $lastOutputAt).TotalSeconds
    } finally { $ErrorActionPreference = 'Stop'; $OutputEncoding=$previousOutputEncoding; [Console]::OutputEncoding=$previousConsoleEncoding; Pop-Location }
    $duration.Stop()
    if ($null -ne $watchdog) {
        [IO.File]::WriteAllText($doneMarker, [DateTime]::UtcNow.ToString('o'))
        if (-not $watchdog.WaitForExit(15000)) { try { $watchdog.Kill() } catch {} }
    }
    if (Test-Path -LiteralPath $timeoutMarker) {
        # Fail closed even if the provider exited at the same moment: 124 matches timeout(1).
        $code = 124
        $record | Add-Member -NotePropertyName timed_out -NotePropertyValue $true -Force
        $record | Add-Member -NotePropertyName idle_seconds_at_exit -NotePropertyValue ([Math]::Round($idleSecondsAtExit, 1)) -Force
        Append-Utf8File $logFile "Harness: worker exceeded max_invocation_seconds=$timeoutSeconds; provider process tree stopped."
    }
    $providerResult=Get-HarnessProviderResult $record $logFile $code
    Complete-HarnessUsageReservation $RootDir $record $logFile $code $duration.Elapsed.TotalSeconds $providerResult
    $record|Add-Member -NotePropertyName provider_result -NotePropertyValue $providerResult -Force
    $record.status = 'exited'
    $record.exit_code = $code
    Write-Utf8File $paths.Record ($record | ConvertTo-Json -Depth 8)
} finally {
    # Unexpected host termination leaves a durable running intent, even after this
    # OS handle disappears. Recovery must never infer child death from a reused PID.
    Release-HarnessLock $lease
}
exit $code
