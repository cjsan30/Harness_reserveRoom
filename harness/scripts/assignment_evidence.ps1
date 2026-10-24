# Evidence is a local workflow integrity check, not a boundary against a writer
# who can forge both code and state. Never infer product correctness from prose.
function Get-AssignmentEvidenceDirectory([string]$RootDir) {
    return Resolve-HarnessEnginePath $RootDir 'harness/state/validation' 'assignment evidence'
}

function Get-AssignmentValidationCommand([string]$Content) {
    $lines=@($Content -split '\r?\n')
    $matches=@($lines | Where-Object { $_ -match '^\s*- validation:' })
    if ($matches.Count -ne 1) { throw 'assignment must have exactly one validation command' }
    $command=Get-MarkdownValue $lines 'validation'
    $issues=@(Get-HarnessValidationCommandIssues $command)
    if($command -match '(?i)^\S+\s+(--version|-v|--help|-h)$') { $issues += 'version/help output is not assignment validation' }
    if($issues.Count) { throw ('invalid assignment validation: '+($issues -join '; ')) }
    return $command
}

function Get-EvidenceFileHash([string]$Path) {
    $stream=[IO.File]::OpenRead($Path)
    $algorithm=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $stream.Dispose();$algorithm.Dispose() }
}

function Get-AssignmentValidationWorkspace([string]$RootDir,[string]$AssignmentId) {
    $worker=Get-AssignmentWorkerRecord $RootDir $AssignmentId
    if($null -ne $worker) { return Resolve-ProjectPath $RootDir $worker.execution_root 'validation workspace' -AllowProjectRoot }
    return [IO.Path]::GetFullPath($RootDir)
}

function Invoke-AssignmentSnapshotGit([string]$Workspace,[ValidateSet('head','branch','index','files','check_index')][string]$Operation,[string]$ExpectedIndexTree='') {
    $commands=@{head='rev-parse --verify HEAD';branch='symbolic-ref --short HEAD';index='write-tree';files='ls-files --cached --others --exclude-standard -z'}
    if($Operation -eq 'check_index'){
        if($ExpectedIndexTree -cnotmatch '^(?:[a-f0-9]{40}|[a-f0-9]{64})$'){throw 'invalid expected index tree'}
        # Dashboard reads must not call write-tree (which creates Git objects).
        $commands.check_index='-c core.fsmonitor=false diff-index --cached --quiet --no-ext-diff --no-textconv '+$ExpectedIndexTree+' --'
    }
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=(Get-Command git -ErrorAction Stop).Source
    $info.Arguments='-c core.fsmonitor=false -c core.untrackedCache=false '+$commands[$Operation];$info.WorkingDirectory=$Workspace
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
    $process=[Diagnostics.Process]::Start($info)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit();$text=$stdout.Result;$null=$stderr.Result
        if($process.ExitCode -ne 0){throw "Git snapshot $Operation failed; evidence cannot be trusted"}
        return $text
    } finally {$process.Dispose()}
}

function Get-AssignmentCodeSnapshot([string]$RootDir,[string]$Workspace,[string]$ReadOnlyIndexTree='') {
    # Native working directory avoids a different worker's CODEX_GIT_WORKSPACE_ROOT.
    $head=(Invoke-AssignmentSnapshotGit $Workspace 'head').Trim()
    $branch=(Invoke-AssignmentSnapshotGit $Workspace 'branch').Trim()
    $index=if($ReadOnlyIndexTree){$null=Invoke-AssignmentSnapshotGit $Workspace 'check_index' $ReadOnlyIndexTree;$ReadOnlyIndexTree}else{(Invoke-AssignmentSnapshotGit $Workspace 'index').Trim()}
    $engineRelative=Get-RelativeProjectPath $RootDir (Get-HarnessEngineRoot $RootDir)
    $prefix=if($engineRelative -in @('.','')){''}else{$engineRelative.Replace('\','/').TrimEnd('/')+'/'}
    $excluded=@('reports/','state/','assignments/') | ForEach-Object {$prefix+$_}
    $listing=Invoke-AssignmentSnapshotGit $Workspace 'files'
    $paths=New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
    foreach($path in $listing.Split([char]0)) {
        if($path.Length -eq 0){continue}
        $skip=$false
        foreach($directory in $excluded){if($path.StartsWith($directory,[StringComparison]::Ordinal)){$skip=$true}}
        if(-not $skip){[void]$paths.Add($path)}
    }
    $entries=New-Object 'System.Collections.Generic.List[object]'
    foreach($path in $paths){
        $absolute=Resolve-ProjectPath $Workspace $path 'validation source'
        if(-not (Test-Path -LiteralPath $absolute)){$entries.Add(@{path=$path;hash='deleted'});continue}
        $item=Get-Item -LiteralPath $absolute -Force
        if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'validation snapshot does not support submodules or linked source files' }
        $entries.Add(@{path=$path;hash=(Get-EvidenceFileHash $absolute)})
    }
    # Ordered pairs avoid hashtable property-order differences between runtimes.
    $text=(@($entries | ForEach-Object { @($_.path,$_.hash) | ConvertTo-Json -Compress }) -join "`n")
    return [pscustomobject]@{head=$head;branch=$branch;index_tree=$index;source_hash=(Get-HarnessTextHash $text);source_files=$entries.Count}
}

function Test-AssignmentSnapshotEqual($Left,$Right) {
    foreach($field in @('head','branch','index_tree','source_hash','source_files')){if($Left.$field -cne $Right.$field){return $false}}
    return $true
}

function Invoke-AssignmentValidationCommand([string]$Workspace,[string]$Command) {
    # Windows PowerShell 5.1 can start in its install directory when its inherited
    # path contains brackets. Run -File validation with a literal location and
    # terminating errors, instead of trusting native startup or a trailing exit 0.
    $pattern='(?i)^(?:pwsh|powershell(?:\.exe)?)\s+(?:(?:-NoProfile)\s+|(?:-ExecutionPolicy)\s+\S+\s+)*-File\s+(.+)$'
    if($Command -match $pattern){
        $tail=$Matches[1]
        if($tail -notmatch '^(?:"([^"]+)"|''([^'']+)''|(\S+))(.*)$'){throw 'cannot parse PowerShell validation script path'}
        $file=if($Matches[1]){$Matches[1]}elseif($Matches[2]){$Matches[2]}else{$Matches[3]}
        $arguments=$Matches[4]
        $path=Resolve-ProjectPath $Workspace $file 'validation script'
        $code="`$ErrorActionPreference='Stop'; Set-Location -LiteralPath '"+$Workspace.Replace("'","''")+"'; `$global:LASTEXITCODE=0; & '"+$path.Replace("'","''")+"'"+$arguments+"; `$commandSucceeded=`$?; if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }; if (-not `$commandSucceeded) { exit 1 }; exit 0"
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $invokeArgs=@('-NoProfile');if(Test-HarnessIsWindows){$invokeArgs+=@('-ExecutionPolicy','Bypass')}
        $invokeArgs+=@('-EncodedCommand',$encoded)
        return Invoke-HarnessProcess (Get-HarnessPowerShellExecutable) $invokeArgs -AllowFailure
    }
    return Invoke-HarnessShellCommand $Workspace $Command -AllowFailure
}

function New-AssignmentValidationEvidence([string]$RootDir,[string]$Owner,[string]$AssignmentId,[string]$Content) {
    $lines=@($Content -split '\r?\n')
    foreach($key in @('assignment_id','status','result')){
        if(@($lines | Where-Object {$_ -match ('^\s*- '+$key+':')}).Count -ne 1){throw 'assignment identity/state metadata is ambiguous'}
    }
    if((Get-MarkdownValue $lines 'assignment_id') -cne $AssignmentId){throw 'assignment identity does not match its filename'}
    $status=Get-MarkdownValue $lines 'status';$result=Get-MarkdownValue $lines 'result'
    if(-not (($status -ceq 'in_progress' -and $result -ceq 'pending') -or ($status -ceq 'done' -and $result -ceq 'pass'))){throw 'assignment state cannot be validated for success'}
    $command=Get-AssignmentValidationCommand $Content
    $workspace=Get-AssignmentValidationWorkspace $RootDir $AssignmentId
    $worker=Get-AssignmentWorkerRecord $RootDir $AssignmentId
    $id=[Guid]::NewGuid().ToString('N')
    $directory=Get-AssignmentEvidenceDirectory $RootDir
    $path=Join-Path $directory ($id+'.json');$log=Join-Path $directory ($id+'.log')
    $before=Get-AssignmentCodeSnapshot $RootDir $workspace
    $evidence=[pscustomobject]@{
        version=1;id=$id;root=[IO.Path]::GetFullPath($RootDir);owner=$Owner;assignment_id=$AssignmentId
        invocation_id=$(if($null -ne $worker){$worker.invocation_id}else{$null});workspace=$workspace
        command=$command;status='running';started_at=[DateTime]::UtcNow.ToString('o');finished_at=$null
        duration_seconds=$null;exit_code=$null;before=$before;after=$null
        log=(Get-RelativeProjectPath $RootDir $log);log_sha256=$null
        assignment_hash=(Get-HarnessTextHash $Content);completed_assignment_hash=$null
        claim='configured_command_execution';product_behavior='not_independently_verified'
    }
    Write-Utf8File $path ($evidence|ConvertTo-Json -Depth 10)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    try {
        $result=Invoke-AssignmentValidationCommand $workspace $command
        Write-Utf8File $log (Protect-HarnessSecretText $result.Output)
        $evidence.exit_code=$result.ExitCode
        $evidence.log_sha256=Get-EvidenceFileHash $log
        $evidence.after=Get-AssignmentCodeSnapshot $RootDir $workspace
        $evidence.status=if($result.Success -and (Test-AssignmentSnapshotEqual $before $evidence.after)){'pass'}else{'fail'}
    } catch {
        $evidence.status='error'
        throw
    } finally {
        $timer.Stop();$evidence.finished_at=[DateTime]::UtcNow.ToString('o');$evidence.duration_seconds=$timer.Elapsed.TotalSeconds
        Write-Utf8File $path ($evidence|ConvertTo-Json -Depth 10)
    }
    if($evidence.status -cne 'pass'){throw "assignment validation failed or code changed during validation; evidence: $id"}
    return $evidence
}

function Assert-AssignmentCompletionEvidence([string]$RootDir,[string]$Owner,[string]$AssignmentId,[string]$Content,[switch]$AllowActiveWorker,[switch]$ReadOnly) {
    $lines=@($Content -split '\r?\n')
    foreach($key in @('assignment_id','status','result')){
        if(@($lines | Where-Object {$_ -match ('^\s*- '+$key+':')}).Count -ne 1){throw 'completion identity/state metadata is ambiguous'}
    }
    if((Get-MarkdownValue $lines 'assignment_id') -cne $AssignmentId -or (Get-MarkdownValue $lines 'status') -cne 'done' -or (Get-MarkdownValue $lines 'result') -cne 'pass'){throw 'completion identity or state is invalid'}
    $ids=@($lines|Where-Object{$_ -match '^\s*- validation_evidence:'})
    if($ids.Count -ne 1){throw 'completion has no unique execution evidence; validation required'}
    $id=Get-MarkdownValue $lines 'validation_evidence'
    if($id -cnotmatch '^[a-f0-9]{32}$'){throw 'invalid validation evidence ID'}
    $path=Join-Path (Get-AssignmentEvidenceDirectory $RootDir) ($id+'.json')
    $evidence=[IO.File]::ReadAllText($path)|ConvertFrom-Json
    if($evidence.version -ne 1 -or $evidence.id -cne $id -or $evidence.owner -cne $Owner -or $evidence.assignment_id -cne $AssignmentId -or
        -not [string]::Equals($evidence.root,[IO.Path]::GetFullPath($RootDir),(Get-HarnessPathComparison)) -or
        $evidence.status -cne 'pass' -or $null -eq $evidence.exit_code -or $evidence.exit_code -ne 0 -or
        $evidence.completed_assignment_hash -cne (Get-HarnessTextHash $Content) -or
        $evidence.command -cne (Get-AssignmentValidationCommand $Content)) {throw 'completion evidence is invalid or belongs to another assignment'}
    $workspace=Get-AssignmentValidationWorkspace $RootDir $AssignmentId
    if(-not [string]::Equals($workspace,$evidence.workspace,(Get-HarnessPathComparison))){throw 'validation workspace changed'}
    $worker=Get-AssignmentWorkerRecord $RootDir $AssignmentId
    if($null -ne $worker){
        if($worker.invocation_id -cne $evidence.invocation_id -or $worker.owner -cne $Owner){throw 'validation belongs to a different worker attempt'}
        if($worker.status -cin @('starting','running')){
            if(-not $AllowActiveWorker -or $env:HARNESS_INVOCATION_ID -cne $worker.invocation_id -or $env:HARNESS_ASSIGNMENT_ID -cne $AssignmentId){throw 'worker exit is not confirmed'}
        } elseif($worker.status -cnotin @('exited','settled') -or $null -eq $worker.exit_code -or $worker.exit_code -ne 0){throw 'worker did not exit successfully'}
        if($worker.status -cin @('exited','settled')){Assert-HarnessWorkerProviderSuccess $worker}
    } elseif($null -ne $evidence.invocation_id){throw 'worker record for evidence is missing'}
    $expectedLog=Join-Path (Get-AssignmentEvidenceDirectory $RootDir) ($id+'.log')
    if($evidence.log -cne (Get-RelativeProjectPath $RootDir $expectedLog) -or $evidence.log_sha256 -cne (Get-EvidenceFileHash $expectedLog)){throw 'validation log is missing or changed'}
    $readIndex=if($ReadOnly){[string]$evidence.after.index_tree}else{''}
    if($ReadOnly -and -not $readIndex){throw 'missing evidence index tree'}
    if(-not (Test-AssignmentSnapshotEqual $evidence.before $evidence.after) -or -not (Test-AssignmentSnapshotEqual $evidence.after (Get-AssignmentCodeSnapshot $RootDir $workspace $readIndex))){throw 'validation evidence is stale; source, branch, index or HEAD changed'}
    return $evidence
}
