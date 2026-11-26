# Environment readiness and operator-declared repairs. Harness, not the worker, runs
# these commands, and only the argv arrays written in the profile's environment
# section. Nothing is installed or started that the operator did not declare.
# Every requirement is first checked for being installed at all; a missing tool is
# never "repaired" and stops before any worker launch with the declared install hint.
$script:HarnessRepairMaxWaitSeconds = 1800
$script:HarnessEnvironmentCheckTimeoutSeconds = 60

function Assert-HarnessCommandArray($Value, [string]$Label) {
    # A single string would be split by a shell later; only an argv array is accepted.
    if ($Value -isnot [array]) { throw "$Label must be a JSON array of strings" }
    $items = @($Value)
    if ($items.Count -eq 0 -or @($items | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { throw "$Label must be a non-empty array of strings" }
    return [string[]]$items
}

function ConvertTo-HarnessInstallHint($Value, [string]$Label) {
    if ($null -eq $Value) { return $null }
    foreach ($field in $Value.PSObject.Properties.Name) { if ($field -cnotin @('text','url')) { throw "unknown field '$field' in $Label install_hint" } }
    if ($Value.text -isnot [string] -or [string]::IsNullOrWhiteSpace($Value.text) -or $Value.text.Length -gt 300) { throw "$Label install_hint needs text of 1..300 characters" }
    if ($null -ne $Value.url -and ($Value.url -isnot [string] -or $Value.url -cnotmatch '^https://[^\s]+$' -or $Value.url.Length -gt 300)) { throw "$Label install_hint url must be an https URL" }
    return [pscustomobject]@{ text = $Value.text.Trim(); url = $(if ($null -ne $Value.url) { [string]$Value.url } else { $null }) }
}

function Format-HarnessInstallHint($Hint) {
    if ($null -eq $Hint) { return 'no install hint declared; decide how to provide it during planning' }
    if ($null -eq $Hint.url) { return $Hint.text }
    return "$($Hint.text) $($Hint.url)"
}

function Get-HarnessEnvironmentConfig([string]$RootDir) {
    $profile = [IO.File]::ReadAllText((Get-ProjectProfilePath $RootDir)) | ConvertFrom-Json
    $section = Get-ProjectObjectProperty $profile 'environment'
    $config = [pscustomobject]@{ declared = ($null -ne $section); requirements = @(); repairs = @{} }
    if ($null -eq $section) { return $config }
    if ($section.version -ne 1) { throw 'environment section must have version 1' }
    foreach ($field in $section.PSObject.Properties.Name) { if ($field -cnotin @('version','requirements','repairs')) { throw "unknown environment field: $field" } }
    $repairs = @{}
    if ($null -ne $section.repairs) {
        foreach ($property in $section.repairs.PSObject.Properties) {
            $id = $property.Name; $repair = $property.Value
            if ($id -cnotmatch '^[a-z0-9][a-z0-9-]{1,63}$') { throw "invalid repair id: $id" }
            foreach ($field in $repair.PSObject.Properties.Name) { if ($field -cnotin @('description','start','run','check','wait_seconds')) { throw "unknown field '$field' in repair $id" } }
            if ([string]::IsNullOrWhiteSpace($repair.description)) { throw "repair $id needs a description" }
            if ($null -eq $repair.start -and $null -eq $repair.run) { throw "repair $id needs start or run" }
            $wait = $repair.wait_seconds
            if (-not (Test-HarnessUsageInteger $wait) -or $wait -lt 1 -or $wait -gt $script:HarnessRepairMaxWaitSeconds) { throw "repair $id wait_seconds must be 1..$($script:HarnessRepairMaxWaitSeconds)" }
            $repairs[$id] = [pscustomobject]@{
                id = $id; description = [string]$repair.description; wait_seconds = [int]$wait
                start = $(if ($null -ne $repair.start) { Assert-HarnessCommandArray $repair.start "repair $id start" } else { $null })
                run = $(if ($null -ne $repair.run) { Assert-HarnessCommandArray $repair.run "repair $id run" } else { $null })
                check = (Assert-HarnessCommandArray $repair.check "repair $id check")
            }
        }
    }
    $requirements = New-Object 'System.Collections.Generic.List[object]'
    foreach ($requirement in @($section.requirements)) {
        if ($null -eq $requirement) { continue }
        foreach ($field in $requirement.PSObject.Properties.Name) { if ($field -cnotin @('id','description','installed','check','repair','install_hint')) { throw "unknown field '$field' in environment requirement" } }
        if ($requirement.id -isnot [string] -or $requirement.id -cnotmatch '^[a-z0-9][a-z0-9-]{1,63}$') { throw 'invalid environment requirement id' }
        if ($null -ne $requirement.repair -and -not $repairs.ContainsKey([string]$requirement.repair)) { throw "requirement $($requirement.id) refers to an undeclared repair: $($requirement.repair)" }
        $requirements.Add([pscustomobject]@{
            id = $requirement.id; description = [string]$requirement.description
            installed = $(if ($null -ne $requirement.installed) { Assert-HarnessCommandArray $requirement.installed "requirement $($requirement.id) installed" } else { $null })
            check = (Assert-HarnessCommandArray $requirement.check "requirement $($requirement.id) check")
            repair = $(if ($null -ne $requirement.repair) { [string]$requirement.repair } else { $null })
            install_hint = (ConvertTo-HarnessInstallHint $requirement.install_hint "requirement $($requirement.id)")
        }) | Out-Null
    }
    $config.requirements = $requirements.ToArray(); $config.repairs = $repairs
    return $config
}

function Start-HarnessArgvProcess([string[]]$Command, [string]$WorkingDirectory, [switch]$Detached) {
    $resolved = Get-Command $Command[0] -ErrorAction SilentlyContinue
    if ($null -eq $resolved) { return $null }
    $path = if ($resolved.CommandType -in @('Application','ExternalScript')) { $resolved.Source } else { $Command[0] }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $arguments = @($Command | Select-Object -Skip 1)
    if ($path -like '*.ps1') {
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path) + $arguments
        $path = Get-HarnessPowerShellExecutable
    }
    if ($Detached -and -not (Test-HarnessIsWindows)) {
        # A long-lived service must not inherit the caller's output (F-23): detach it
        # through sh with its standard streams on /dev/null.
        $arguments = @('-c', 'exec "$0" "$@" </dev/null >/dev/null 2>&1 &', $path) + $arguments
        $path = '/bin/sh'
    }
    $startInfo.FileName = $path
    $startInfo.Arguments = ($arguments | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' '
    $startInfo.WorkingDirectory = $WorkingDirectory
    if ($Detached -and (Test-HarnessIsWindows)) {
        # ShellExecute does not inherit handles, so a started service (Docker Desktop)
        # cannot hold the pipe of a parent that captures harness output (F-23).
        $startInfo.UseShellExecute = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        return [Diagnostics.Process]::Start($startInfo)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    if (-not $Detached) {
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
    }
    $process = [Diagnostics.Process]::Start($startInfo)
    if (-not $Detached) { $process.StandardInput.Close() }
    return $process
}

function Invoke-HarnessArgvCommand([string[]]$Command, [string]$WorkingDirectory, [int]$TimeoutSeconds) {
    $process = Start-HarnessArgvProcess $Command $WorkingDirectory
    if ($null -eq $process) { return [pscustomobject]@{ Success = $false; Output = "command not found: $($Command[0])"; TimedOut = $false } }
    $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch {}
        return [pscustomobject]@{ Success = $false; Output = "timed out after $TimeoutSeconds seconds"; TimedOut = $true }
    }
    $process.WaitForExit()
    $output = Protect-HarnessSecretText (($stdout.Result + $stderr.Result).Trim())
    if ($output.Length -gt 1000) { $output = $output.Substring($output.Length - 1000) }
    return [pscustomobject]@{ Success = ($process.ExitCode -eq 0); Output = $output; TimedOut = $false }
}

function Test-HarnessEnvironmentCheck([string]$RootDir, [string[]]$Check) {
    return Invoke-HarnessArgvCommand $Check ([IO.Path]::GetFullPath($RootDir)) $script:HarnessEnvironmentCheckTimeoutSeconds
}

function Invoke-HarnessEnvironmentRepair([string]$RootDir, [string]$RepairId) {
    $config = Get-HarnessEnvironmentConfig $RootDir
    if (-not $config.repairs.ContainsKey($RepairId)) {
        return [pscustomobject]@{ Success = $false; RepairId = $RepairId; Message = "repair '$RepairId' is not declared in the profile environment section" }
    }
    $repair = $config.repairs[$RepairId]
    $root = [IO.Path]::GetFullPath($RootDir)
    if ((Test-HarnessEnvironmentCheck $root $repair.check).Success) {
        return [pscustomobject]@{ Success = $true; RepairId = $RepairId; Message = "$RepairId check already passes" }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($repair.wait_seconds)
    if ($null -ne $repair.run) {
        $result = Invoke-HarnessArgvCommand $repair.run $root $repair.wait_seconds
        if (-not $result.Success) { return [pscustomobject]@{ Success = $false; RepairId = $RepairId; Message = "repair $RepairId command failed: $($result.Output)" } }
    }
    if ($null -ne $repair.start) {
        $started = Start-HarnessArgvProcess $repair.start $root -Detached
        if ($null -eq $started) { return [pscustomobject]@{ Success = $false; RepairId = $RepairId; Message = "repair $RepairId start command not found: $($repair.start[0])" } }
    }
    $last = $null
    while ($true) {
        $last = Test-HarnessEnvironmentCheck $root $repair.check
        if ($last.Success) { return [pscustomobject]@{ Success = $true; RepairId = $RepairId; Message = "$RepairId repaired: $($repair.description)" } }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Seconds 2
    }
    return [pscustomobject]@{ Success = $false; RepairId = $RepairId; Message = "repair $RepairId did not make its check pass within $($repair.wait_seconds) seconds: $($last.Output)" }
}

function Get-HarnessBuiltInRequirements([string]$RootDir) {
    # Tools the harness itself runs. Only their presence is checked; they are never installed.
    $provider = Get-HarnessConfiguredProvider $RootDir
    $providerCommand = if ($provider -eq 'claude') { $env:HARNESS_CLAUDE_PATH } else { $env:HARNESS_CODEX_PATH }
    if ([string]::IsNullOrWhiteSpace($providerCommand)) { $providerCommand = $provider }
    $providerHint = if ($provider -eq 'claude') {
        [pscustomobject]@{ text = 'Install Claude Code and sign in, or set HARNESS_CLAUDE_PATH:'; url = 'https://docs.anthropic.com/en/docs/claude-code/setup' }
    } else {
        [pscustomobject]@{ text = 'Install the Codex CLI and sign in, or set HARNESS_CODEX_PATH:'; url = 'https://github.com/openai/codex' }
    }
    return @(
        [pscustomobject]@{ id = 'harness-git'; description = 'Git for branches, worktrees and gates'; command = 'git'; install_hint = [pscustomobject]@{ text = 'Install Git:'; url = 'https://git-scm.com/downloads' } },
        [pscustomobject]@{ id = 'harness-provider'; description = "$provider CLI for workers"; command = $providerCommand; install_hint = $providerHint }
    )
}

function Get-HarnessCheckSummary([string]$Output) {
    # Checks such as `docker info` print pages of text; the error is in the last lines.
    $lines = @(($Output -split "\r?\n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lines.Count -eq 0) { return 'check failed without output' }
    return (@($lines | Select-Object -Last 3) -join ' / ')
}

function Test-HarnessCommandInstalled([string]$Command) {
    $resolved = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1
    return ($null -ne $resolved -and $resolved.CommandType -in @('Application','ExternalScript'))
}

function Test-HarnessRequirementInstalled([string]$RootDir, $Requirement) {
    if ($null -ne $Requirement.installed) { return (Test-HarnessEnvironmentCheck $RootDir $Requirement.installed) }
    $command = @($Requirement.check)[0]
    if (Test-HarnessCommandInstalled $command) { return [pscustomobject]@{ Success = $true; Output = "found: $command"; TimedOut = $false } }
    return [pscustomobject]@{ Success = $false; Output = "command not found: $command"; TimedOut = $false }
}

function New-HarnessMissingRequirement($Requirement, [string]$Source, [string]$Detail) {
    return [pscustomobject]@{
        id = $Requirement.id; source = $Source; description = $Requirement.description; state = 'missing'; repair = $null
        install_hint = $Requirement.install_hint
        message = "not installed ($Detail). $(Format-HarnessInstallHint $Requirement.install_hint) Then run: harness.ps1 env"
    }
}

function Get-HarnessEnvironmentReadiness([string]$RootDir, [switch]$Repair) {
    $config = Get-HarnessEnvironmentConfig $RootDir
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($builtIn in Get-HarnessBuiltInRequirements $RootDir) {
        if (Test-HarnessCommandInstalled $builtIn.command) {
            $items.Add([pscustomobject]@{ id = $builtIn.id; source = 'harness'; description = $builtIn.description; state = 'ok'; repair = $null; install_hint = $builtIn.install_hint; message = 'installed' }) | Out-Null
        } else {
            $items.Add((New-HarnessMissingRequirement $builtIn 'harness' "command not found: $($builtIn.command)")) | Out-Null
        }
    }
    foreach ($requirement in $config.requirements) {
        # Installed first: a missing tool is a planning decision, not something to start or retry.
        $installed = Test-HarnessRequirementInstalled $RootDir $requirement
        if (-not $installed.Success) {
            $items.Add((New-HarnessMissingRequirement $requirement 'profile' $installed.Output)) | Out-Null
            continue
        }
        $check = Test-HarnessEnvironmentCheck $RootDir $requirement.check
        $state = if ($check.Success) { 'ok' } elseif ($null -ne $requirement.repair) { 'repairable' } else { 'needs_decision' }
        $message = if ($check.Success) { 'check passed' } else { Get-HarnessCheckSummary $check.Output }
        if ($state -eq 'repairable' -and $Repair) {
            $repaired = Invoke-HarnessEnvironmentRepair $RootDir $requirement.repair
            $state = if ($repaired.Success) { 'repaired' } else { 'repair_failed' }
            $message = $repaired.Message
        }
        $items.Add([pscustomobject]@{ id = $requirement.id; source = 'profile'; description = $requirement.description; state = $state; repair = $requirement.repair; install_hint = $requirement.install_hint; message = $message }) | Out-Null
    }
    # Known errors that name a repair the profile does not declare would stop a run
    # instead of repairing it; surface them at planning time.
    $undeclared = @(Get-HarnessKnownErrorCatalog $RootDir | Where-Object { $null -ne $_.repair -and -not $config.repairs.ContainsKey($_.repair) } | ForEach-Object { $_.repair } | Select-Object -Unique)
    $blocking = @($items | Where-Object { $_.state -in @('missing','needs_decision','repair_failed','repairable') })
    $status = if ($blocking.Count -gt 0) { 'blocked' } elseif (-not $config.declared -or @($config.requirements).Count -eq 0) { 'undeclared' } else { 'ready' }
    return [pscustomobject]@{ status = $status; declared = $config.declared; requirements = $items.ToArray(); undeclared_repairs = $undeclared }
}
