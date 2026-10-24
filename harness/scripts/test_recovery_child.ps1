param([string]$Mode, [string]$RootDir, [string]$Stage, [string]$SignalPath, [string]$StopPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
switch ($Mode) {
    'Transition' {
        $lease = Enter-AssignmentQueue $RootDir 'tester'
        try {
            $script:HarnessTransitionCheckpoint = {
                param($point)
                if ($point -eq $Stage) {
                    Write-Utf8File $SignalPath 'ready'
                    while ($true) { Start-Sleep -Milliseconds 100 }
                }
            }
            $dirs = Get-AssignmentDirectories $RootDir 'tester'
            Move-FileWithUpdatedContent (Join-Path $dirs.Inbox 'task.md') (Join-Path $dirs.InProgress 'task.md') "- assignment_id: task`n- status: in_progress`n- result: pending`n" $lease
        } finally { Release-HarnessLock $lease }
    }
    'Repair' {
        if ($StopPath) { while (-not (Test-Path -LiteralPath $StopPath)) { Start-Sleep -Milliseconds 20 } }
        try { $lease = Enter-AssignmentQueue $RootDir 'tester'; Release-HarnessLock $lease; Write-Utf8File $SignalPath 'repaired' }
        catch { Write-Utf8File $SignalPath 'blocked'; exit 2 }
    }
    'FakeWorker' {
        Write-Utf8File $SignalPath ([string]$PID)
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while (-not (Test-Path -LiteralPath $StopPath)) {
            if ([DateTime]::UtcNow -gt $deadline) { exit 5 }
            Start-Sleep -Milliseconds 30
        }
        Write-Output 'fake worker finished'
        exit 0
    }
    'Parent' {
        $lease = Acquire-HarnessLock (Get-HarnessLockRoot $RootDir) 'invoke_task'
        try {
            $workerArgs = @('-NoProfile')
            if (Test-HarnessIsWindows) { $workerArgs += @('-ExecutionPolicy', 'Bypass') }
            $workerArgs += @('-File', $PSCommandPath, '-Mode', 'FakeWorker', '-RootDir', $RootDir, '-SignalPath', $SignalPath, '-StopPath', $StopPath)
            $promptFile = Join-Path $RootDir 'prompt.md'
            Write-Utf8File $promptFile 'isolated fake worker'
            $intent = New-AssignmentWorkerIntent $RootDir 'tester' 'task' $lease (Get-HarnessPowerShellExecutable) $workerArgs $promptFile (Join-Path $RootDir 'worker.log') $RootDir
            $result = Invoke-HarnessPowerShellFile (Join-Path $PSScriptRoot 'run_assignment_worker.ps1') @('-RootDir', $RootDir, '-AssignmentId', 'task', '-InvocationId', $intent.invocation_id) -AllowFailure
            exit $result.ExitCode
        } finally { Release-HarnessLock $lease }
    }
    default { throw 'unknown recovery test child mode' }
}
