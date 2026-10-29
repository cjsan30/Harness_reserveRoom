param([string]$OutputDirectory = "")

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
. (Join-Path $PSScriptRoot 'git_workflow_common.ps1')
$engineRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $engineRoot '.test-output' }
$testRoot = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ([Guid]::NewGuid().ToString('N'))
Ensure-HarnessDirectory $testRoot
$results = New-Object 'System.Collections.Generic.List[object]'
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $results.Add(@{name=$Name; passed=$true}); Write-Output "PASS $Name" }
    catch { $results.Add(@{name=$Name; passed=$false; error=$_.Exception.Message}); Write-Output "FAIL $Name : $($_.Exception.Message)" }
}
function Run-Child([string]$File, [object[]]$Arguments = @()) {
    Invoke-HarnessPowerShellFile -FilePath $File -Arguments $Arguments -AllowFailure
}
# Field finding F-22: Git writes UTF-8, but a Korean Windows console decodes native
# output as code page 949. Non-ASCII repository paths must survive a git round trip.
Test-Case 'git output keeps non-ASCII paths under a code page 949 console' {
    $korean = [string][char]0xD55C + [char]0xAE00
    $repo = Join-Path $testRoot ("git utf8 $korean [safe]")
    Invoke-HarnessProcess git @('init', '-q', $repo) | Out-Null
    $value = Join-Path $repo ".githooks $korean"
    Invoke-HarnessProcess git @('-C', $repo, 'config', 'core.hooksPath', $value) | Out-Null
    $previous = [Console]::OutputEncoding
    $legacy = $null
    try { $legacy = [Text.Encoding]::GetEncoding(949) } catch { $legacy = $null }
    try {
        if ($null -ne $legacy -and (Test-HarnessIsWindows)) { [Console]::OutputEncoding = $legacy }
        $read = (Invoke-HarnessProcess git @('-C', $repo, 'config', '--get', 'core.hooksPath')).Output.Trim()
        Assert-True ($read -ceq $value) "git output was decoded with the console code page: $read"
        Assert-True ([Console]::OutputEncoding.CodePage -eq $(if ($null -ne $legacy -and (Test-HarnessIsWindows)) { 949 } else { $previous.CodePage })) 'console encoding was not restored'
    } finally { [Console]::OutputEncoding = $previous }
}
function Start-LockChild([string]$Name, [string]$Signal, [string]$StartSignal = '') {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Get-HarnessPowerShellExecutable
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    # Values here are generated fixture paths. Windows file names cannot contain quotes.
    $argsList = @('-NoProfile')
    if (Test-HarnessIsWindows) { $argsList += @('-ExecutionPolicy', 'Bypass') }
    $argsList += @('-File', (Join-Path $PSScriptRoot 'test_lock_child.ps1'), '-CommonPath', (Join-Path $PSScriptRoot 'harness_common.ps1'), '-LockRoot', $testRoot, '-LockName', $Name, '-SignalPath', $Signal)
    if ($StartSignal) { $argsList += @('-StartSignal', $StartSignal) }
    $info.Arguments = ($argsList | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
    return [Diagnostics.Process]::Start($info)
}
function Wait-Signal([string]$Path) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $Path)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw "child did not produce signal: $Path" }
        Start-Sleep -Milliseconds 25
    }
    return [IO.File]::ReadAllText($Path)
}

$previousRoot = $env:CODEX_HARNESS_ROOT
$previousWorkspace = $env:CODEX_GIT_WORKSPACE_ROOT
$previousGh = $env:HARNESS_GH_PATH
$previousFakeState = $env:HARNESS_TEST_GH_STATE
$env:CODEX_GIT_WORKSPACE_ROOT = $null
try {
    # A real, isolated Git repository. No remote, installed hook, provider, or network access.
    $fixture = Join-Path $testRoot 'target [safe]'
    Ensure-HarnessDirectory (Join-Path $fixture 'harness/project/configs')
    Copy-Item -LiteralPath (Join-Path $engineRoot 'scripts') -Destination (Join-Path $fixture 'harness/scripts') -Recurse
    Copy-Item -LiteralPath (Join-Path $engineRoot 'configs/project_profile.template.json') -Destination (Join-Path $fixture 'harness/project/configs/project_profile.json')
    $env:CODEX_HARNESS_ROOT = $fixture
    Invoke-HarnessProcess git @('init', '-b', 'main', $fixture) | Out-Null
    Write-Utf8File (Join-Path $fixture 'sample.txt') 'baseline'
    Invoke-HarnessProcess git @('-C', $fixture, 'add', 'sample.txt') | Out-Null
    Invoke-HarnessProcess git @('-C', $fixture, '-c', 'core.hooksPath=', '-c', 'user.name=Harness Test', '-c', 'user.email=test@example.invalid', 'commit', '-m', 'fixture') | Out-Null
    Invoke-HarnessProcess git @('-C', $fixture, 'branch', 'test/candidate') | Out-Null
    $head = (Invoke-HarnessProcess git @('-C', $fixture, 'rev-parse', 'HEAD')).Output.Trim()
    $tree = (Invoke-HarnessProcess git @('-C', $fixture, 'rev-parse', 'HEAD^{tree}')).Output.Trim()
    $statePath = Join-Path $fixture 'harness/state/git_workflow/state.json'
    $approval = @{id='approval-fixture'; source_branch='test/candidate'; source_head=$head; source_tree=$tree; target_branch='main'; repository_root=$fixture; stage='final'; status='approved'; requested_at='2026-01-01T00:00:00Z'}
    function Write-FixtureState {
        $state = @{version=1; approvals=@($approval); promotions=@(); validations=@(@{branch='test/candidate'; tree_hash=$tree; stage='final'; status='pass'; recorded_at='2026-01-01T00:00:00Z'})}
        Write-Utf8File $statePath ($state | ConvertTo-Json -Depth 10)
    }
    Test-Case 'matching approval permits promotion' {
        Write-FixtureState
        $r = Run-Child (Join-Path $PSScriptRoot 'authorize_branch_promotion.ps1') @('-RepositoryRoot', $fixture, '-SourceBranch', 'test/candidate', '-TargetBranch', 'main', '-ApprovalId', 'approval-fixture')
        Assert-True $r.Success $r.Output
    }
    foreach ($field in @('source_branch', 'source_head', 'target_branch', 'repository_root', 'stage')) {
        Test-Case "foreign approval $field is rejected" {
            $original = $approval[$field]
            try {
                $approval[$field] = 'foreign-value'
                Write-FixtureState
                $r = Run-Child (Join-Path $PSScriptRoot 'authorize_branch_promotion.ps1') @('-RepositoryRoot', $fixture, '-SourceBranch', 'test/candidate', '-TargetBranch', 'main', '-ApprovalId', 'approval-fixture')
                Assert-True (-not $r.Success) "promotion accepted a different $field"
            } finally { $approval[$field] = $original }
        }
    }
    Test-Case 'legacy unbound approval is rejected' {
        $approval.Remove('repository_root')
        try {
            Write-FixtureState
            $r = Run-Child (Join-Path $PSScriptRoot 'authorize_branch_promotion.ps1') @('-RepositoryRoot', $fixture, '-SourceBranch', 'test/candidate', '-TargetBranch', 'main')
            Assert-True (-not $r.Success) 'legacy approval accepted without a repository binding'
        } finally { $approval.repository_root = $fixture }
    }
    Test-Case 'optimistic state update prevents lost approvals' {
        Write-FixtureState
        $loaded = Get-GitWorkflowState $fixture
        $concurrent = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        $concurrent.approvals += [pscustomobject]@{id='other-writer'}
        Write-Utf8File $statePath ($concurrent | ConvertTo-Json -Depth 10)
        $rejected = $false
        try { Save-GitWorkflowState $fixture $loaded | Out-Null } catch { $rejected = $true }
        Assert-True $rejected 'stale writer overwrote concurrent state'
        Assert-True ([IO.File]::ReadAllText($statePath).Contains('other-writer')) 'concurrent approval was lost'
    }
    Test-Case 'approval request and decision retain repository scope' {
        Write-FixtureState
        $empty = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        $empty.approvals = @()
        Write-Utf8File $statePath ($empty | ConvertTo-Json -Depth 10)
        $r = Run-Child (Join-Path $PSScriptRoot 'request_main_merge_approval.ps1') @('-RepositoryRoot', $fixture, '-SourceBranch', 'test/candidate')
        Assert-True $r.Success $r.Output
        $saved = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        $id = $saved.approvals[0].id
        $r = Run-Child (Join-Path $PSScriptRoot 'set_main_merge_approval.ps1') @('-RepositoryRoot', $fixture, '-ApprovalId', $id, '-Status', 'approved', '-Approver', 'fixture')
        Assert-True $r.Success $r.Output
        $saved = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        Assert-True ($saved.approvals[0].repository_root -eq $fixture -and $saved.approvals[0].status -eq 'approved') 'approval binding missing'
    }
    Test-Case 'decision rejects a request for a different commit' {
        $old = $approval.source_head
        try {
            $approval.source_head = '0000000000000000000000000000000000000000'
            Write-FixtureState
            $r = Run-Child (Join-Path $PSScriptRoot 'set_main_merge_approval.ps1') @('-RepositoryRoot', $fixture, '-ApprovalId', 'approval-fixture', '-Status', 'approved', '-Approver', 'fixture')
            Assert-True (-not $r.Success) 'stale request was approved'
            Assert-True ($r.Output.Contains('approval scope or validation changed')) 'failed for an unrelated reason'
        } finally { $approval.source_head = $old }
    }
    # Only this explicitly selected fake CLI is used; tests cannot contact GitHub.
    $ghState = Join-Path $testRoot 'fake-gh'
    Ensure-HarnessDirectory $ghState
    $env:HARNESS_TEST_GH_STATE = $ghState
    $env:HARNESS_GH_PATH = Join-Path $testRoot 'fake-gh.ps1'
    Write-Utf8File (Join-Path $ghState 'pr.json') (@{number=1; url='https://example.invalid/pr/1'; state='OPEN'; isDraft=$false; headRefName='test/candidate'; headRefOid=$head; baseRefName='main'} | ConvertTo-Json)
    Write-Utf8File $env:HARNESS_GH_PATH @'
if ($args[0] -eq 'pr' -and $args[1] -eq 'view') { Get-Content -Raw -LiteralPath (Join-Path $env:HARNESS_TEST_GH_STATE 'pr.json'); exit 0 }
if ($args[0] -eq 'pr' -and $args[1] -eq 'checks') { '[{"name":"Harness CI","bucket":"pass"}]'; exit 0 }
if ($args[0] -eq 'pr' -and $args[1] -eq 'merge') { [IO.File]::WriteAllText((Join-Path $env:HARNESS_TEST_GH_STATE 'merged'), ($args -join ' ')); 'merged'; exit 0 }
exit 1
'@
    Test-Case 'PR merge rejects a foreign approval before calling merge' {
        $old = $approval.source_branch
        try {
            $approval.source_branch = 'test/other'
            Write-FixtureState
            $r = Run-Child (Join-Path $PSScriptRoot 'merge_pr_if_allowed.ps1') @('-RepositoryRoot', $fixture, '-PullRequest', '1', '-ApprovalId', 'approval-fixture')
            Assert-True (-not $r.Success) 'PR merge accepted foreign approval'
            Assert-True ($r.Output.Contains('approved local main merge approval')) 'PR failed before testing approval'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $ghState 'merged'))) 'merge side effect occurred'
        } finally { $approval.source_branch = $old }
    }
    Test-Case 'matching PR merge pins the remote head' {
        Write-FixtureState
        $r = Run-Child (Join-Path $PSScriptRoot 'merge_pr_if_allowed.ps1') @('-RepositoryRoot', $fixture, '-PullRequest', '1', '-ApprovalId', 'approval-fixture')
        Assert-True $r.Success $r.Output
        Assert-True ([IO.File]::ReadAllText((Join-Path $ghState 'merged')).Contains("--match-head-commit $head")) 'remote head not pinned'
    }
    Test-Case 'local merge checks authorization even without hooks' {
        # Ignore fixture runtime files so rejection is due to authorization, not dirtiness.
        Write-Utf8File (Join-Path $fixture '.git/info/exclude') "*`n"
        Write-FixtureState
        $r = Run-Child (Join-Path $PSScriptRoot 'merge_authorized_branch.ps1') @('-RepositoryRoot', $fixture, '-SourceBranch', 'test/candidate', '-TargetBranch', 'main')
        Assert-True (-not $r.Success) 'unauthorized local merge accepted'
        Assert-True ($r.Output.Contains('merge requires an authorization')) 'merge failed for an unrelated reason'
        Assert-True ((Invoke-HarnessProcess git @('-C', $fixture, 'rev-parse', 'HEAD')).Output.Trim() -eq $head) 'merge changed HEAD'
    }
    Test-Case 'runtime output masks credentials but keeps usage counters' {
        $previousEnvSecret = $env:FIXTURE_SERVICE_TOKEN
        try {
            $env:FIXTURE_SERVICE_TOKEN = 'plainvalue-from-environment-7391'
            $samples = @(
                'key sk-proj-abcdefghijklmnopqrstuvwx1234',
                'gh token ghp_abcdefghijklmnopqrstuvwxyz0123456789',
                'Authorization: Bearer abcdefghijklmnop.qrstuvwx',
                'clone https://user:hunter2secret@example.invalid/repo.git',
                '{"api_key":"fixture-json-secret-value","model":"m"}',
                'DATABASE_PASSWORD=fixture-assignment-secret',
                "-----BEGIN RSA PRIVATE KEY-----`nMIIfixturekeymaterial`n-----END RSA PRIVATE KEY-----",
                'echo plainvalue-from-environment-7391'
            )
            $leaks = @('abcdefghijklmnopqrstuvwx1234', 'abcdefghijklmnopqrstuvwxyz0123456789', 'abcdefghijklmnop.qrstuvwx', 'hunter2secret', 'fixture-json-secret-value', 'fixture-assignment-secret', 'MIIfixturekeymaterial', 'plainvalue-from-environment-7391')
            for ($i = 0; $i -lt $samples.Count; $i++) {
                $masked = Protect-HarnessSecretText $samples[$i]
                Assert-True (-not $masked.Contains($leaks[$i])) "secret survived masking: $masked"
                Assert-True ($masked.Contains('[REDACTED]')) "no redaction marker: $masked"
            }
            $usage = '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20}}'
            Assert-True ((Protect-HarnessSecretText $usage) -ceq $usage) 'usage counters were altered'
            Assert-True ((Protect-HarnessSecretText '{"model":"m","max_tokens":null}') -ceq '{"model":"m","max_tokens":null}') 'null setting was altered'
        } finally { $env:FIXTURE_SERVICE_TOKEN = $previousEnvSecret }
    }
    Test-Case 'git gate logs mask credentials printed by the gate command' {
        $logPath = Join-Path $testRoot 'gate-mask.log'
        $result = Invoke-LoggedShellCommand -RootDir $fixture -CommandText 'git --version && echo token=fixture-gate-secret-value-42' -LogPath $logPath
        Assert-True $result.Success $result.Output
        $text = [IO.File]::ReadAllText($logPath)
        Assert-True (-not $text.Contains('fixture-gate-secret-value-42') -and -not $result.Output.Contains('fixture-gate-secret-value-42')) "gate output leaked: $text"
        Assert-True ($text.Contains('git version')) 'ordinary gate output was lost'
    }
    Test-Case 'manifest never copies secret section values' {
        $intake = "## Project`n- language: python`n- framework: none`n## Requirements`nA fixture application.`n## Prepared Data`nnone`n## External Dependencies`nnone`n## Secrets And Access`n- SERVICE_TOKEN=FAKE_SENSITIVE_VALUE_7391`n- password: arbitrary-private-text-7391`n- prose private content 7391`n"
        Write-Utf8File (Join-Path $fixture 'intake.md') $intake
        $r = Run-Child (Join-Path $fixture 'harness/scripts/generate_env_manifest.ps1') @('-IntakeFile', 'intake.md')
        Assert-True $r.Success $r.Output
        $artifacts = @('docs/env_manifest.md', '.env.example', 'harness/reports/sensitive_followups.md')
        foreach ($path in $artifacts) {
            $text = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $fixture $path)
            Assert-True (-not $text.Contains('7391')) "secret section leaked into $path"
        }
        Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $fixture '.env.example')).Contains('SERVICE_TOKEN=')) 'variable name lost'
    }
    Test-Case 'misplaced credential blocks intake without echoing its value' {
        Write-Utf8File (Join-Path $fixture 'unsafe.md') "## Requirements`nSERVICE_TOKEN=private-fixture-5929`n"
        foreach ($scriptName in @('generate_env_manifest.ps1', 'review_project_intake.ps1', 'start_from_intake.ps1')) {
            $r = Run-Child (Join-Path $fixture "harness/scripts/$scriptName") @('-IntakeFile', 'unsafe.md')
            Assert-True (-not $r.Success) "$scriptName accepted a misplaced credential"
            Assert-True (-not $r.Output.Contains('private-fixture-5929')) "$scriptName echoed the credential"
            Assert-True ($r.Output.Contains('possible credential outside')) "$scriptName failed for an unrelated reason"
        }
    }
    Test-Case 'requirements and profile generation cannot copy secret section' {
        Copy-Item -LiteralPath (Join-Path $engineRoot 'configs') -Destination (Join-Path $fixture 'harness/configs') -Recurse
        $r = Run-Child (Join-Path $fixture 'harness/scripts/start_from_intake.ps1') @('-IntakeFile', 'intake.md', '-Force', '-SkipSeedPlan', '-SkipIntakeReview')
        Assert-True $r.Success $r.Output
        foreach ($directory in @('docs', 'harness/project', 'harness/reports')) {
            foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $fixture $directory) -File -Recurse)) {
                Assert-True (-not [IO.File]::ReadAllText($file.FullName).Contains('7391')) 'secret copied into a generated artifact'
            }
        }
    }
    Test-Case 'live lock cannot expire by age' {
        $lock = Acquire-HarnessLock -LockRoot $testRoot -LockName 'live' -MaxAgeSeconds 1
        try {
            [IO.File]::SetLastWriteTimeUtc((Join-Path $lock 'lock.meta'), [DateTime]::UtcNow.AddDays(-1))
            Assert-True (Test-HarnessLockActive $lock -MaxAgeSeconds 1 -CleanStale) 'live lock expired'
            Assert-True ($null -eq (Acquire-HarnessLock $testRoot 'live' -MaxAgeSeconds 1)) 'duplicate lock acquired'
        } finally { Release-HarnessLock $lock }
    }
    Test-Case 'another process cannot release owner lock' {
        $lock = Acquire-HarnessLock $testRoot 'owned'
        try {
            $child = Join-Path $testRoot 'release.ps1'
            $common = (Join-Path $PSScriptRoot 'harness_common.ps1').Replace("'", "''")
            Write-Utf8File $child ("param([string]`$LockPath)`n. '$common'`nRelease-HarnessLock -LockPath `$LockPath")
            $r = Run-Child $child @('-LockPath', $lock)
            Assert-True (-not $r.Success) 'non-owner release reported success'
            Assert-True (Test-HarnessLockActive $lock) 'foreign process released lock'
        } finally { Release-HarnessLock $lock }
    }
    Test-Case 'unknown legacy lock is not removed by age' {
        $legacy = Join-Path $testRoot 'legacy'
        Write-Utf8File (Join-Path $legacy 'lock.meta') 'created_at: unknown'
        [IO.File]::SetLastWriteTimeUtc((Join-Path $legacy 'lock.meta'), [DateTime]::UtcNow.AddDays(-1))
        Assert-True (Test-HarnessLockActive $legacy -MaxAgeSeconds 1 -CleanStale) 'unknown owner silently removed'
        Assert-True ($null -eq (Acquire-HarnessLock $testRoot 'legacy' -MaxAgeSeconds 1)) 'legacy lock was overwritten'
    }
    Test-Case 'old lease cannot release a new owner in the same process' {
        $oldLease = Acquire-HarnessLock $testRoot 'reacquire'
        Release-HarnessLock $oldLease
        $newLease = Acquire-HarnessLock $testRoot 'reacquire'
        try {
            $rejected = $false
            try { Release-HarnessLock $oldLease } catch { $rejected = $true }
            Assert-True $rejected 'old lease released a new owner'
            Update-HarnessLock $newLease
            Assert-True (Test-HarnessLockActive $newLease) 'new lease no longer active'
        } finally { Release-HarnessLock $newLease }
    }
    Test-Case 'killed owner permits immediate lock recovery' {
        $signal = Join-Path $testRoot 'killed.signal'
        $child = Start-LockChild 'killed' $signal
        try {
            Assert-True ((Wait-Signal $signal) -eq 'acquired') 'child did not acquire lock'
            Assert-True (Test-HarnessLockActive (Join-Path $testRoot 'killed')) 'child lease not detected'
            $child.Kill(); $child.WaitForExit()
            Assert-True (-not (Test-HarnessLockActive (Join-Path $testRoot 'killed'))) 'terminated owner still active'
            $recovered = Acquire-HarnessLock $testRoot 'killed'
            Assert-True ($null -ne $recovered) 'recovery could not acquire lease'
            Release-HarnessLock $recovered
        } finally { if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit() }; $child.Dispose() }
    }
    Test-Case 'simultaneous processes have only one lock owner' {
        $start = Join-Path $testRoot 'race.start'
        $signals = @(1..4 | ForEach-Object { Join-Path $testRoot "race-$_.signal" })
        $children = @()
        try {
            foreach ($signal in $signals) { $children += Start-LockChild 'race' $signal $start }
            Write-Utf8File $start 'go'
            $states = @($signals | ForEach-Object { Wait-Signal $_ })
            Assert-True (@($states | Where-Object { $_ -eq 'acquired' }).Count -eq 1) 'multiple or no lock owners'
            Assert-True (@($states | Where-Object { $_ -eq 'blocked' }).Count -eq 3) 'contending process did not fail closed'
        } finally { foreach ($child in $children) { if (-not $child.HasExited) { $child.Kill(); $child.WaitForExit() }; $child.Dispose() } }
    }
    Test-Case 'atomic overwrite preserves unicode and clears temporary files' {
        $file = Join-Path $testRoot 'atomic/state.json'
        Write-Utf8File $file '{"value":"first"}'
        $unicode = ([string][char]0xD55C) + [char]0xAE00 + ' second'
        Write-Utf8File $file (@{value=$unicode} | ConvertTo-Json)
        Assert-True (([IO.File]::ReadAllText($file) | ConvertFrom-Json).value -eq $unicode) 'JSON damaged'
        Assert-True (@(Get-ChildItem -LiteralPath (Split-Path -Parent $file) -File).Count -eq 1) 'temporary files leaked'
    }
} finally {
    $env:CODEX_HARNESS_ROOT = $previousRoot
    $env:CODEX_GIT_WORKSPACE_ROOT = $previousWorkspace
    $env:HARNESS_GH_PATH = $previousGh
    $env:HARNESS_TEST_GH_STATE = $previousFakeState
    Write-Utf8File (Join-Path $testRoot 'results.json') ($results.ToArray() | ConvertTo-Json -Depth 5)
}
$failed = @($results | Where-Object { -not $_.passed }).Count
Write-Output "Results: $($results.Count - $failed)/$($results.Count) passed; artifacts: $testRoot"
if ($failed -gt 0) { exit 1 }
