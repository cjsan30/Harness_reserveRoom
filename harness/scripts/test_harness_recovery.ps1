param([string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$engineRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $engineRoot '.test-output' }
$testRoot = Join-Path $OutputDirectory ([Guid]::NewGuid().ToString('N'))
Ensure-HarnessDirectory $testRoot
$results = New-Object 'System.Collections.Generic.List[object]'
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Rejected([scriptblock]$Body, [string]$Message) {
    $rejected = $false
    try { & $Body | Out-Null } catch { $rejected = $true }
    Assert-True $rejected $Message
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $results.Add(@{name=$Name; passed=$true}); Write-Output "PASS $Name" }
    catch { $results.Add(@{name=$Name; passed=$false; error=$_.Exception.Message}); Write-Output "FAIL $Name : $($_.Exception.Message)" }
}
function New-Fixture {
    $fixture = Join-Path $testRoot ('target [safe] ' + [Guid]::NewGuid().ToString('N'))
    Ensure-HarnessDirectory (Join-Path $fixture 'harness/project/configs')
    Copy-Item -LiteralPath (Join-Path $engineRoot 'configs/project_profile.template.json') -Destination (Join-Path $fixture 'harness/project/configs/project_profile.json')
    $dirs = Get-AssignmentDirectories $fixture 'tester'
    Write-Utf8File (Join-Path $dirs.Inbox 'task.md') "- assignment_id: task`n- status: inbox`n- result: pending`n"
    return $fixture
}
function Start-Child([string]$Mode, [string]$Fixture, [string]$Signal, [string]$Stage = '', [string]$StopPath = '') {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Get-HarnessPowerShellExecutable
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $childArgs = @('-NoProfile')
    if (Test-HarnessIsWindows) { $childArgs += @('-ExecutionPolicy', 'Bypass') }
    $childArgs += @('-File', (Join-Path $PSScriptRoot 'test_recovery_child.ps1'), '-Mode', $Mode, '-RootDir', $Fixture, '-SignalPath', $Signal)
    if ($Stage) { $childArgs += @('-Stage', $Stage) }
    if ($StopPath) { $childArgs += @('-StopPath', $StopPath) }
    $info.Arguments = ($childArgs | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
    return [Diagnostics.Process]::Start($info)
}
function Wait-Until([scriptblock]$Condition) {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (& $Condition)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'timed out waiting for fixture process' }
        Start-Sleep -Milliseconds 25
    }
}
function Stop-FixtureProcess($Process) {
    if ($null -ne $Process) {
        if (-not $Process.HasExited) { $Process.Kill(); $Process.WaitForExit() }
        $Process.Dispose()
    }
}
function Interrupt-Transition([string]$Fixture, [string]$Stage) {
    $signal = Join-Path $Fixture 'transition.signal'
    $child = Start-Child 'Transition' $Fixture $signal $Stage
    try { Wait-Until { Test-Path -LiteralPath $signal } }
    finally { Stop-FixtureProcess $child }
}
function Set-Progress([string]$Fixture) {
    $dirs = Get-AssignmentDirectories $Fixture 'tester'
    $lease = Enter-AssignmentQueue $Fixture 'tester'
    try { Move-FileWithUpdatedContent (Join-Path $dirs.Inbox 'task.md') (Join-Path $dirs.InProgress 'task.md') "- assignment_id: task`n- status: in_progress`n- result: pending`n" $lease }
    finally { Release-HarnessLock $lease }
}
try {
    Test-Case 'claim and completion preserve UTF-8 task text' {
        $fixture = New-Fixture
        $dirs = Get-AssignmentDirectories $fixture 'tester'
        $unicode = [string][char]0xD55C + [char]0xAE00
        Append-Utf8File (Join-Path $dirs.Inbox 'task.md') ("- task: " + $unicode)
        $previous = $env:CODEX_HARNESS_ROOT
        try {
            $env:CODEX_HARNESS_ROOT = $fixture
            $r = Invoke-HarnessPowerShellFile (Join-Path $PSScriptRoot 'claim_assignment.ps1') @('-Agent','tester','-AssignmentId','task') -AllowFailure
            Assert-True $r.Success $r.Output
            Assert-True ([IO.File]::ReadAllText((Join-Path $dirs.InProgress 'task.md')).Contains($unicode)) 'claim corrupted UTF-8'
            $r = Invoke-HarnessPowerShellFile (Join-Path $PSScriptRoot 'complete_assignment.ps1') @('-Agent','tester','-AssignmentId','task','-Result','fail') -AllowFailure
            Assert-True $r.Success $r.Output
            Assert-True ([IO.File]::ReadAllText((Join-Path $dirs.Done 'task__fail.md')).Contains($unicode)) 'completion corrupted UTF-8'
        } finally { $env:CODEX_HARNESS_ROOT = $previous }
    }
    foreach ($stage in @('intent_written', 'target_written', 'source_removed')) {
        Test-Case "killed queue writer recovers after $stage" {
            $fixture = New-Fixture
            $dirs = Get-AssignmentDirectories $fixture 'tester'
            Interrupt-Transition $fixture $stage
            foreach ($attempt in 1..2) { $lease = Enter-AssignmentQueue $fixture 'tester'; Release-HarnessLock $lease }
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $dirs.Inbox 'task.md'))) 'source survived reconciliation'
            Assert-True ([IO.File]::ReadAllText((Join-Path $dirs.InProgress 'task.md')).Contains('status: in_progress')) 'destination was lost'
            $journal = @(Get-ChildItem -LiteralPath (Join-Path $dirs.Root '.transitions') -Filter '*.json' -File)
            Assert-True (([IO.File]::ReadAllText($journal[0].FullName) | ConvertFrom-Json).status -eq 'committed') 'journal was not committed'
        }
    }
    foreach ($side in @('source', 'target')) {
        Test-Case "conflicting $side blocks reconciliation without overwriting" {
            $fixture = New-Fixture
            $dirs = Get-AssignmentDirectories $fixture 'tester'
            Interrupt-Transition $fixture 'target_written'
            $path = if ($side -eq 'source') { Join-Path $dirs.Inbox 'task.md' } else { Join-Path $dirs.InProgress 'task.md' }
            Write-Utf8File $path 'concurrent edit'
            Assert-Rejected { $lease = Enter-AssignmentQueue $fixture 'tester'; Release-HarnessLock $lease } 'conflict was accepted'
            Assert-True ([IO.File]::ReadAllText($path) -eq 'concurrent edit') 'conflicting content changed'
            Assert-True (Test-Path -LiteralPath (Join-Path $dirs.Inbox 'task.md')) 'source removed on conflict'
        }
    }
    Test-Case 'corrupt journal fails closed' {
        $fixture = New-Fixture
        $dirs = Get-AssignmentDirectories $fixture 'tester'
        Write-Utf8File (Join-Path $dirs.Root '.transitions/broken.json') '{invalid'
        Assert-Rejected { Enter-AssignmentQueue $fixture 'tester' } 'corrupt journal accepted'
        Assert-True (Test-Path -LiteralPath (Join-Path $dirs.Inbox 'task.md')) 'assignment lost'
    }
    Test-Case 'journal path escape is rejected before mutation' {
        $fixture = New-Fixture
        $dirs = Get-AssignmentDirectories $fixture 'tester'
        Interrupt-Transition $fixture 'intent_written'
        $file = Get-ChildItem -LiteralPath (Join-Path $dirs.Root '.transitions') -Filter '*.json' -File | Select-Object -First 1
        $record = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
        $record.target = '../outside.md'
        Write-Utf8File $file.FullName ($record | ConvertTo-Json)
        Assert-Rejected { Enter-AssignmentQueue $fixture 'tester' } 'unsafe path accepted'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $dirs.Root) 'outside.md'))) 'outside path created'
    }
    Test-Case 'two simultaneous reconcilers preserve one queue destination' {
        $fixture = New-Fixture
        Interrupt-Transition $fixture 'target_written'
        $start = Join-Path $fixture 'start'
        $children = @()
        try {
            foreach ($i in 1..2) { $children += Start-Child 'Repair' $fixture (Join-Path $fixture "repair-$i") '' $start }
            Write-Utf8File $start 'go'
            foreach ($child in $children) { Assert-True ($child.WaitForExit(20000)) 'repair process timed out' }
            $lease = Enter-AssignmentQueue $fixture 'tester'; Release-HarnessLock $lease
            $dirs = Get-AssignmentDirectories $fixture 'tester'
            Assert-True (@(Get-ChildItem -LiteralPath $dirs.InProgress -File).Count -eq 1) 'destination duplicated or lost'
            Assert-True (@(Get-ChildItem -LiteralPath $dirs.Inbox -File).Count -eq 0) 'source still queued'
        } finally { foreach ($child in $children) { Stop-FixtureProcess $child } }
    }
    Test-Case 'completion retry is idempotent and conflicting result is rejected' {
        $fixture = New-Fixture
        Set-Progress $fixture
        $previous = $env:CODEX_HARNESS_ROOT
        try {
            $env:CODEX_HARNESS_ROOT = $fixture
            foreach ($attempt in 1..2) {
                $r = Invoke-HarnessPowerShellFile (Join-Path $PSScriptRoot 'complete_assignment.ps1') @('-Agent', 'tester', '-AssignmentId', 'task', '-Result', 'fail') -AllowFailure
                Assert-True $r.Success $r.Output
            }
            $r = Invoke-HarnessPowerShellFile (Join-Path $PSScriptRoot 'complete_assignment.ps1') @('-Agent', 'tester', '-AssignmentId', 'task', '-Result', 'pass') -AllowFailure
            Assert-True (-not $r.Success) 'completion changed from pass to fail'
        } finally { $env:CODEX_HARNESS_ROOT = $previous }
    }
    Test-Case 'durable prelaunch intent blocks recovery and duplicate start' {
        $fixture = New-Fixture
        Set-Progress $fixture
        $lease = Acquire-HarnessLock (Get-HarnessLockRoot $fixture) 'invoke_task'
        try {
            $intent = New-AssignmentWorkerIntent $fixture 'tester' 'task' $lease 'unused' @() (Join-Path $fixture 'prompt') (Join-Path $fixture 'log') $fixture
            Assert-Rejected { New-AssignmentWorkerIntent $fixture 'tester' 'task' $lease 'unused' @() '' '' $fixture } 'duplicate launch allowed'
        } finally { Release-HarnessLock $lease }
        $recovered = @(Restore-StaleInProgressAssignments $fixture 'tester' 0)
        Assert-True ($recovered.Count -eq 0) 'starting worker requeued'
        Assert-Rejected { Repair-AssignmentWorkerExit $fixture 'tester' 'task' } 'unknown exit reconciled'
        $r = Invoke-HarnessPowerShellFile (Join-Path $PSScriptRoot 'run_assignment_worker.ps1') @('-RootDir', $fixture, '-AssignmentId', 'task', '-InvocationId', 'wrong') -AllowFailure
        Assert-True (-not $r.Success) 'wrong invocation launched'
    }
    foreach ($unresolvedKind in @('queue', 'worker')) {
        Test-Case "seed resume never reports pass with unresolved $unresolvedKind state" {
            $fixture = New-Fixture
            Set-Progress $fixture
            $dirs = Get-AssignmentDirectories $fixture 'tester'
            $progress = Join-Path $dirs.InProgress 'task.md'
            $source = [IO.File]::ReadAllText($progress) + "- source_plan_id: recovery-plan`n- seed_task_key: tester|sample`n"
            Write-Utf8File $progress $source
            Write-Utf8File (Join-Path $fixture 'plan.md') "- plan_id: recovery-plan`n`n## Assignment`n- owner: tester`n- title: sample`n`n### Task`nA fixture task.`n"
            $lease = Enter-AssignmentQueue $fixture 'tester'
            try {
                if ($unresolvedKind -eq 'queue') { $script:HarnessTransitionCheckpoint = { param($stage) if ($stage -eq 'target_written') { throw 'fixture interruption' } } }
                try { Move-FileWithUpdatedContent $progress (Join-Path $dirs.Done 'task__pass.md') ($source.Replace('status: in_progress', 'status: done').Replace('result: pending', 'result: pass')) $lease }
                catch { if ($unresolvedKind -ne 'queue') { throw } }
            } finally { Remove-Variable HarnessTransitionCheckpoint -Scope Script -ErrorAction SilentlyContinue; Release-HarnessLock $lease }
            if ($unresolvedKind -eq 'worker') {
                $invoke = Acquire-HarnessLock (Get-HarnessLockRoot $fixture) 'invoke_task'
                try { New-AssignmentWorkerIntent $fixture 'tester' 'task' $invoke 'unused' @() '' '' $fixture | Out-Null }
                finally { Release-HarnessLock $invoke }
            }
            $previous = $env:CODEX_HARNESS_ROOT
            try {
                $env:CODEX_HARNESS_ROOT = $fixture
                $r = Invoke-HarnessPowerShellFile (Join-Path $PSScriptRoot 'get_seed_handoff_resume.ps1') @('-PlanFile', 'plan.md', '-Json') -AllowFailure
                Assert-True $r.Success $r.Output
                $report = [IO.File]::ReadAllText((Join-Path $fixture 'harness/reports/seed_plans/recovery-plan__resume.json')) | ConvertFrom-Json
                Assert-True ($report.counts.passed -eq 0) 'unresolved completion counted as passed'
                Assert-True ($report.assignments[0].state -ceq ($unresolvedKind + '_unresolved')) 'resume omitted reconciliation status'
            } finally { $env:CODEX_HARNESS_ROOT = $previous }
        }
    }
    Test-Case 'actual invocation entrypoint settles a fake worker in an isolated Git worktree' {
        $fixture = New-Fixture
        Copy-Item -LiteralPath (Join-Path $engineRoot 'scripts') -Destination (Join-Path $fixture 'harness/scripts') -Recurse
        Copy-Item -LiteralPath (Join-Path $engineRoot 'configs') -Destination (Join-Path $fixture 'harness/configs') -Recurse
        Invoke-HarnessProcess git @('init', '-b', 'main', $fixture) | Out-Null
        Write-Utf8File (Join-Path $fixture 'baseline.txt') 'fixture'
        Invoke-HarnessProcess git @('-C', $fixture, 'add', 'baseline.txt') | Out-Null
        Invoke-HarnessProcess git @('-C', $fixture, '-c', 'core.hooksPath=', '-c', 'user.name=Harness Test', '-c', 'user.email=test@example.invalid', 'commit', '-m', 'fixture') | Out-Null
        Write-Utf8File (Join-Path $fixture 'harness/reports/dispatch_packets/task.md') 'fake packet'
        Append-Utf8File (Join-Path (Get-AssignmentDirectories $fixture 'tester').Inbox 'task.md') '- validation: git cat-file -e HEAD:baseline.txt'
        $fakeCodex = Join-Path $fixture 'fake-codex.ps1'
        Write-Utf8File $fakeCodex @'
if ($args -contains '--version') { 'fake-codex for isolated test'; return }
if ($args[0] -ne 'exec') { throw 'unexpected fake command' }
. (Join-Path $env:CODEX_HARNESS_ROOT 'harness/scripts/harness_common.ps1')
$r = Invoke-HarnessPowerShellFile (Join-Path $env:CODEX_HARNESS_ROOT 'harness/scripts/complete_assignment.ps1') @('-Agent', 'tester', '-AssignmentId', 'task', '-Result', 'pass') -AllowFailure
if (-not $r.Success) { throw $r.Output }
$global:LASTEXITCODE = 0
'fake completed'
'@
        $previousRoot = $env:CODEX_HARNESS_ROOT; $previousWorkspace = $env:CODEX_GIT_WORKSPACE_ROOT; $previousCodex = $env:HARNESS_CODEX_PATH
        try {
            $env:CODEX_HARNESS_ROOT = $fixture; $env:CODEX_GIT_WORKSPACE_ROOT = $null; $env:HARNESS_CODEX_PATH = $fakeCodex
            $r = Invoke-HarnessPowerShellFile (Join-Path $PSScriptRoot 'invoke_assignment_codex.ps1') @('-Agent', 'tester', '-AssignmentId', 'task') -AllowFailure
            Assert-True $r.Success $r.Output
            $record = Get-AssignmentWorkerRecord $fixture 'task'
            Assert-True ($record.status -ceq 'settled') 'entrypoint left a successful worker unresolved'
            Assert-True ($record.execution_root -ne $fixture) 'worker did not use an isolated worktree'
            Assert-True ([IO.File]::ReadAllText($record.log_file).Contains('fake completed')) 'worker output missing'
        } finally { $env:CODEX_HARNESS_ROOT = $previousRoot; $env:CODEX_GIT_WORKSPACE_ROOT = $previousWorkspace; $env:HARNESS_CODEX_PATH = $previousCodex }
    }
    foreach ($killHost in @($false, $true)) {
        $name = if ($killHost) { 'dead supervisor with live child stays quarantined despite reused PID metadata' } else { 'orphan worker remains exclusive and confirmed exit reconciles without rerun' }
        Test-Case $name {
            $fixture = New-Fixture
            Set-Progress $fixture
            $signal = Join-Path $fixture 'worker.signal'
            $stop = Join-Path $fixture 'worker.stop'
            $parent = $null; $hostProcess = $null; $native = $null
            try {
                $parent = Start-Child 'Parent' $fixture $signal '' $stop
                Wait-Until { Test-Path -LiteralPath $signal }
                $native = Get-Process -Id ([int][IO.File]::ReadAllText($signal))
                $record = Get-AssignmentWorkerRecord $fixture 'task'
                $hostProcess = Get-Process -Id $record.worker_pid
                $parent.Kill(); $parent.WaitForExit()
                Assert-True (-not $native.HasExited) 'fixture worker did not survive parent'
                if ($killHost) {
                    $hostProcess.Kill(); $hostProcess.WaitForExit()
                    # A stale PID pointing to this unrelated test process must not
                    # authorize recovery or cause that process to be terminated.
                    $record.worker_pid = $PID
                    $record.worker_started_at = '2000-01-01T00:00:00Z'
                    Write-Utf8File (Get-AssignmentWorkerPaths $fixture 'task').Record ($record | ConvertTo-Json -Depth 8)
                }
                Assert-True (Test-AssignmentWorkerUnsettled $fixture 'task') 'orphan was considered settled'
                Assert-True (@(Restore-StaleInProgressAssignments $fixture 'tester' 0).Count -eq 0) 'orphan was requeued'
                Assert-Rejected { Repair-AssignmentWorkerExit $fixture 'tester' 'task' } 'live or ambiguous worker reconciled'
                Assert-True (-not $native.HasExited) 'recovery killed worker'
                Write-Utf8File $stop 'finish'
                Assert-True ($native.WaitForExit(20000)) 'fake worker did not exit'
                if (-not $killHost) {
                    Assert-True ($hostProcess.WaitForExit(20000)) 'supervisor did not exit'
                    Repair-AssignmentWorkerExit $fixture 'tester' 'task'
                    Repair-AssignmentWorkerExit $fixture 'tester' 'task'
                    Assert-True (-not (Test-AssignmentWorkerUnsettled $fixture 'task')) 'confirmed exit remained blocked'
                    $dirs = Get-AssignmentDirectories $fixture 'tester'
                    Assert-True (Test-Path -LiteralPath (Join-Path $dirs.Done 'task__fail.md')) 'unvalidated completion was not marked fail'
                    Assert-True (@(Get-ChildItem -LiteralPath $dirs.Inbox -File).Count -eq 0) 'worker was silently requeued'
                } else {
                    Assert-True (Test-AssignmentWorkerUnsettled $fixture 'task') 'unconfirmed exit was inferred from PID'
                }
            } finally {
                if ($stop) { Write-Utf8File $stop 'finish' }
                Stop-FixtureProcess $parent; Stop-FixtureProcess $hostProcess; Stop-FixtureProcess $native
            }
        }
    }
} finally { Write-Utf8File (Join-Path $testRoot 'results.json') ($results.ToArray() | ConvertTo-Json -Depth 5) }
$failed = @($results | Where-Object { -not $_.passed }).Count
Write-Output "Recovery results: $($results.Count - $failed)/$($results.Count) passed; artifacts: $testRoot"
if ($failed) { exit 1 }
