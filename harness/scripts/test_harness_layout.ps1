param([string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$engineSource = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $engineSource '.test-output' }
$testRoot = Join-Path $OutputDirectory ([Guid]::NewGuid().ToString('N'))
Ensure-HarnessDirectory $testRoot
$results = New-Object 'System.Collections.Generic.List[object]'
function Find-GitBundledTool([string]$GitPath,[string]$Name){
    # git.exe is cmd\git.exe from Windows PATH but mingw64\bin\git.exe inside Git Bash;
    # walk up to the Git install root that has bin\<tool>.
    $directory=Split-Path -Parent $GitPath
    for($i=0;$i -lt 4 -and $directory;$i++){
        $candidate=Join-Path $directory ('bin/'+$Name)
        if(Test-Path -LiteralPath $candidate){return $candidate}
        $directory=Split-Path -Parent $directory
    }
    return (Join-Path (Split-Path -Parent (Split-Path -Parent $GitPath)) ('bin/'+$Name))
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $results.Add(@{name=$Name; passed=$true}); Write-Output "PASS $Name" }
    catch { $results.Add(@{name=$Name; passed=$false; error=$_.Exception.Message}); Write-Output "FAIL $Name : $($_.Exception.Message)" }
}
$oldRoot=$env:CODEX_HARNESS_ROOT; $oldWorkspace=$env:CODEX_GIT_WORKSPACE_ROOT; $oldNotify=$env:HARNESS_NOTIFY_DISABLED; $oldCi=$env:HARNESS_CI_MODE; $oldPs=$env:CODEX_HARNESS_PWSH
try {
    $env:CODEX_HARNESS_ROOT=$null; $env:CODEX_GIT_WORKSPACE_ROOT=$null; $env:HARNESS_NOTIFY_DISABLED='1'; $env:HARNESS_CI_MODE='true'
    $env:CODEX_HARNESS_PWSH=(Get-HarnessPowerShellExecutable).Replace('\','/')
    foreach ($layout in @('standalone','nested')) {
        $unicode = [string][char]0xD55C + [char]0xAE00
        $fixture = Join-Path $testRoot "$layout $unicode [safe]"
        $engine = if ($layout -eq 'standalone') { $fixture } else { Join-Path $fixture 'harness' }
        Ensure-HarnessDirectory $engine
        foreach ($dir in @('scripts','configs','docs','githooks','project')) { Copy-Item -LiteralPath (Join-Path $engineSource $dir) -Destination (Join-Path $engine $dir) -Recurse }
        Copy-Item -LiteralPath (Join-Path $engineSource 'AGENT.md') -Destination (Join-Path $engine 'AGENT.md')
        Test-Case "$layout root discovery before Git init" {
            Assert-True ((Get-HarnessRoot (Join-Path $engine 'scripts')) -eq $fixture) 'root escaped fixture'
            Assert-True ((Get-HarnessEngineRoot $fixture) -eq $engine) 'wrong engine root'
        }
        Invoke-HarnessProcess git @('init','-b','main',$fixture) | Out-Null
        Test-Case "$layout initialization and profile preserve custom text" {
            $r=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/init_project_adapter.ps1') @('-ProjectName','layout-fixture','-Language','c11','-Framework','none','-Requirements','Keep harness/scripts/custom as literal requirement text.','-Force') -AllowFailure
            Assert-True $r.Success $r.Output
            $path=Join-Path $engine 'project/configs/project_profile.json'
            Assert-True (Test-Path -LiteralPath $path) 'profile written to wrong layout'
            $profile=[IO.File]::ReadAllText($path)|ConvertFrom-Json
            Assert-True ($profile.project.summary.Contains('harness/scripts/custom')) 'requirements rewritten'
            $expected=if($layout -eq 'standalone'){'scripts/run_harness_cycle.ps1'}else{'harness/scripts/run_harness_cycle.ps1'}
            Assert-True ($profile.commands.full_cycle -eq "pwsh -NoProfile -File $expected") 'default cycle command has wrong prefix'
            Assert-True ((Get-HarnessLockRoot $fixture) -eq (Join-Path $engine 'state/locks')) 'lock path has wrong layout'
            foreach($property in $profile.commands.PSObject.Properties){$property.Value='git --version'}
            foreach($property in $profile.owners.PSObject.Properties){$property.Value.validation='git --version'}
            Write-Utf8File $path ($profile|ConvertTo-Json -Depth 20)
            Clear-ProjectProfileCache $fixture
        }
        Test-Case "$layout hooks and preflight execute from special-character path" {
            $r=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/install_git_hooks.ps1') -AllowFailure
            Assert-True $r.Success $r.Output
            $r=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/run_harness_preflight.ps1') -AllowFailure
            Assert-True $r.Success $r.Output
            Write-Utf8File (Join-Path $fixture 'baseline.txt') 'fixture'
            Invoke-HarnessProcess git @('-C',$fixture,'add','baseline.txt') | Out-Null
            Invoke-HarnessProcess git @('-C',$fixture,'-c','core.hooksPath=','-c','user.name=Harness Test','-c','user.email=test@example.invalid','commit','-m','fixture') | Out-Null
            $r=Invoke-HarnessProcess git @('-C',$fixture,'-c','user.name=Harness Test','-c','user.email=test@example.invalid','commit','--allow-empty','-m','must be blocked') -AllowFailure
            Assert-True (-not $r.Success) 'protected commit was accepted'
            Assert-True ($r.Output -match 'direct commits|blocked|protected') ("hook did not reach policy: " + $r.Output)
        }
        Test-Case "$layout actual cycle writes reports in engine directory" {
            $r=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/run_harness_cycle.ps1') @('-SkipRetryPrompt') -AllowFailure
            Assert-True $r.Success $r.Output
            Assert-True (Test-Path -LiteralPath (Join-Path $engine 'reports/latest_report.md')) 'report written outside engine layout'
            $shellCommand=Get-Command 'sh' -ErrorAction SilentlyContinue
            $shellPath=if($null -ne $shellCommand){$shellCommand.Source}else{Find-GitBundledTool (Get-Command git).Source 'sh.exe'}
            Assert-True (Test-Path -LiteralPath $shellPath) 'POSIX shell unavailable for cycle test'
            $r=Invoke-HarnessProcess $shellPath @((Join-Path $engine 'scripts/run_harness_cycle.sh').Replace('\','/'),'--skip-retry-prompt') -WorkingDirectory $fixture -AllowFailure
            Assert-True $r.Success ("shell cycle: " + $r.Output)
            if($layout -eq 'standalone'){ Assert-True (-not(Test-Path -LiteralPath (Join-Path $fixture 'harness'))) 'phantom nested engine created' }
        }
        Test-Case "$layout generated CI and worktree hooks resolve engine" {
            $r=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/install_github_actions_workflow.ps1') @('-Force') -AllowFailure
            Assert-True $r.Success $r.Output
            $yaml=[IO.File]::ReadAllText((Join-Path $fixture '.github/workflows/harness-ci.yml'))
            if($layout -eq 'standalone'){Assert-True (-not $yaml.Contains('harness/scripts/')) 'generated CI has nested path'}
            $worktree=Join-Path $fixture 'isolated worktree [safe]'
            Invoke-HarnessProcess git @('-C',$fixture,'worktree','add','-b','test/layout',$worktree,'main') | Out-Null
            $r=Invoke-HarnessProcess git @('-C',$worktree,'-c','user.name=Harness Test','-c','user.email=test@example.invalid','commit','--allow-empty','-m','must be blocked') -AllowFailure
            Assert-True (-not $r.Success) 'worktree protected commit accepted'
            Assert-True ($r.Output -match 'direct commits|blocked|protected') ("worktree hook failed before policy: " + $r.Output)
        }
        Test-Case "$layout worker completion uses actual engine and preserves task text" {
            $dirs=Get-AssignmentDirectories $fixture 'agent-tests'
            Write-Utf8File (Join-Path $dirs.Inbox 'layout-task.md') "- assignment_id: layout-task`n- status: inbox`n- result: pending`n- task: Preserve harness/scripts/custom in the task text.`n- validation: git cat-file -e HEAD:baseline.txt`n"
            Write-Utf8File (Join-Path $engine 'reports/dispatch_packets/layout-task.md') ('Preserve harness/scripts/custom as literal task input. ' + $unicode)
            $fake=Join-Path $fixture 'fake-codex.ps1'
            Write-Utf8File $fake @'
if($args -contains '--version'){'isolated fake'; return}
if($args -contains '--full-auto' -or $args -notcontains '--json' -or $args -notcontains 'workspace-write'){throw 'unsupported Codex invocation flags'}
. (Join-Path $env:HARNESS_TEST_ENGINE 'scripts/harness_common.ps1')
$r=Invoke-HarnessPowerShellFile (Join-Path $env:HARNESS_TEST_ENGINE 'scripts/complete_assignment.ps1') @('-Agent','agent-tests','-AssignmentId','layout-task','-Result','pass') -AllowFailure
if(-not $r.Success){throw $r.Output}
$global:LASTEXITCODE=0
'{"type":"turn.started"}'
'{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20}}'
'@
            $oldCodex=$env:HARNESS_CODEX_PATH; $oldEngine=$env:HARNESS_TEST_ENGINE
            try {
                $env:HARNESS_CODEX_PATH=$fake; $env:HARNESS_TEST_ENGINE=$engine
                $preview=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/invoke_assignment_codex.ps1') @('-Agent','agent-tests','-AssignmentId','layout-task','-DryRun') -AllowFailure
                Assert-True $preview.Success $preview.Output
                Assert-True (@(Read-HarnessUsageRecords $fixture).Count -eq 0) 'dry run consumed a reservation'
                $r=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/invoke_assignment_codex.ps1') @('-Agent','agent-tests','-AssignmentId','layout-task') -AllowFailure
                Assert-True $r.Success $r.Output
                Assert-True ((Get-AssignmentWorkerRecord $fixture 'layout-task').status -eq 'settled') 'worker not settled'
                $usage=@(Read-HarnessUsageRecords $fixture)
                Assert-True ($usage.Count -eq 1 -and $usage[0].usage.status -eq 'known' -and $usage[0].usage.input_tokens -eq 100) 'worker usage not persisted'
                $prompt=[IO.File]::ReadAllText((Join-Path $engine 'reports/agent_runs/layout-task__prompt.md'))
                Assert-True ($prompt.Contains('Preserve harness/scripts/custom')) 'task text was rewritten'
                Assert-True ($prompt.Contains($unicode)) 'UTF-8 packet text was corrupted'
                $completePath=if($layout -eq 'standalone'){'scripts/complete_assignment.ps1'}else{'harness/scripts/complete_assignment.ps1'}
                Assert-True ($prompt.Contains("-File $completePath")) 'wrong completion command'
                $profilePath=Join-Path $engine 'project/configs/project_profile.json'
                $profile=[IO.File]::ReadAllText($profilePath)|ConvertFrom-Json
                $profile.execution_policy.max_invocations=1
                Write-Utf8File $profilePath ($profile|ConvertTo-Json -Depth 20)
                Write-Utf8File (Join-Path $dirs.Inbox 'blocked-task.md') "- assignment_id: blocked-task`n- status: inbox`n- result: pending`n- task: Must not launch.`n- validation: git --version`n"
                Write-Utf8File (Join-Path $engine 'reports/dispatch_packets/blocked-task.md') 'Must not launch.'
                $denied=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/invoke_assignment_codex.ps1') @('-Agent','agent-tests','-AssignmentId','blocked-task') -AllowFailure
                Assert-True (-not $denied.Success -and $denied.Output -match 'max_invocations') 'launch cap bypassed at entrypoint'
                Assert-True ($null -eq (Get-AssignmentWorkerRecord $fixture 'blocked-task') -and @(Read-HarnessUsageRecords $fixture).Count -eq 1) 'denied worker was launched'
                Assert-True (Test-Path -LiteralPath (Join-Path $dirs.InProgress 'blocked-task.md')) 'policy refusal was incorrectly marked as implementation failure'
            } finally {$env:HARNESS_CODEX_PATH=$oldCodex; $env:HARNESS_TEST_ENGINE=$oldEngine}
        }
        Test-Case "$layout generated environment and release paths audit" {
            foreach($script in @('install_dev_environment.ps1','install_release_provenance_workflow.ps1')) {
                $r=Invoke-HarnessPowerShellFile (Join-Path $engine "scripts/$script") @('-Force') -AllowFailure
                Assert-True $r.Success $r.Output
            }
            foreach($script in @('audit_dev_environment.ps1','audit_release_provenance.ps1')) {
                $r=Invoke-HarnessPowerShellFile (Join-Path $engine "scripts/$script") -AllowFailure
                Assert-True $r.Success $r.Output
            }
        }
    }
    Test-Case 'ambiguous layout and engine path escape fail closed' {
        $fixture=Join-Path $testRoot 'ambiguous'
        Write-Utf8File (Join-Path $fixture 'scripts/harness_common.ps1') '# marker'
        Write-Utf8File (Join-Path $fixture 'harness/scripts/harness_common.ps1') '# marker'
        $blocked=$false; try { Get-HarnessEngineRoot $fixture | Out-Null } catch { $blocked=$true }
        Assert-True $blocked 'ambiguous engine selected'
        $blocked=$false; try { Resolve-HarnessEnginePath $engineSource 'harness/../../escape' | Out-Null } catch { $blocked=$true }
        Assert-True $blocked 'path escaped root'
    }
} finally {
    $env:CODEX_HARNESS_ROOT=$oldRoot; $env:CODEX_GIT_WORKSPACE_ROOT=$oldWorkspace; $env:HARNESS_NOTIFY_DISABLED=$oldNotify; $env:HARNESS_CI_MODE=$oldCi; $env:CODEX_HARNESS_PWSH=$oldPs
    Write-Utf8File (Join-Path $testRoot 'results.json') ($results.ToArray()|ConvertTo-Json -Depth 5)
}
$failed=@($results|Where-Object {-not $_.passed}).Count
Write-Output "Layout results: $($results.Count-$failed)/$($results.Count) passed; artifacts: $testRoot"
if($failed){exit 1}
