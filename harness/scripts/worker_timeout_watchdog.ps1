param(
    [Parameter(Mandatory = $true)][int]$HostPid,
    [Parameter(Mandatory = $true)][string]$HostStartedAt,
    [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
    [Parameter(Mandatory = $true)][string]$TimeoutMarker,
    [Parameter(Mandatory = $true)][string]$DoneMarker,
    # Linux: the worker record's /proc identity (boot id + start ticks). .NET StartTime
    # on Linux is a wall-clock estimate that differs between processes.
    [string]$HostIdentity = ''
)

# Started by run_assignment_worker.ps1 when the intent has timeout_seconds. When the
# limit passes it records the timeout first, then stops every descendant process of
# the worker host (the provider tree) but never the host itself, so the host can still
# record a confirmed exit. It acts only while the host's PID still has the recorded
# start time (or, on Linux, /proc identity); a reused PID is never touched.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')

function Test-WatchedHostAlive {
    if (-not [string]::IsNullOrWhiteSpace($HostIdentity)) {
        return ((Get-HarnessLinuxProcessIdentity $HostPid) -ceq $HostIdentity)
    }
    $process = Get-Process -Id $HostPid -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    try {
        return ($process.StartTime.ToUniversalTime().ToString('o') -eq $HostStartedAt)
    } catch {
        return $false
    }
}

function Get-ProcessParentMap {
    $map = @{}
    if (Test-HarnessIsWindows) {
        foreach ($process in @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId)) {
            $map[[int]$process.ProcessId] = [int]$process.ParentProcessId
        }
    } else {
        foreach ($line in @(& ps -A -o 'pid=,ppid=')) {
            $parts = @(([string]$line).Trim() -split '\s+')
            if ($parts.Count -ge 2) { $map[[int]$parts[0]] = [int]$parts[1] }
        }
    }
    return $map
}

function Get-DescendantProcessIds([int]$RootPid) {
    $map = Get-ProcessParentMap
    $result = New-Object 'System.Collections.Generic.List[int]'
    $frontier = New-Object 'System.Collections.Generic.Queue[int]'
    $frontier.Enqueue($RootPid)
    while ($frontier.Count -gt 0) {
        $parent = $frontier.Dequeue()
        foreach ($entry in $map.GetEnumerator()) {
            if ($entry.Value -eq $parent -and $entry.Key -ne $parent -and -not $result.Contains($entry.Key)) {
                $result.Add($entry.Key) | Out-Null
                $frontier.Enqueue($entry.Key)
            }
        }
    }
    return $result.ToArray()
}

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
while ([DateTime]::UtcNow -lt $deadline) {
    if ((Test-Path -LiteralPath $DoneMarker) -or -not (Test-WatchedHostAlive)) { exit 0 }
    Start-Sleep -Milliseconds 500
}
if ((Test-Path -LiteralPath $DoneMarker) -or -not (Test-WatchedHostAlive)) { exit 0 }

[IO.File]::WriteAllText($TimeoutMarker, [DateTime]::UtcNow.ToString('o'))

# Deepest descendants first so a parent cannot respawn a stopped child.
$targets = @(Get-DescendantProcessIds $HostPid | Where-Object { $_ -ne $PID })
[array]::Reverse($targets)
foreach ($targetPid in $targets) {
    if (-not (Test-WatchedHostAlive)) { break }
    try {
        Stop-Process -Id $targetPid -Force -ErrorAction Stop
    } catch {
        # Already exited, or not stoppable; the host records whatever exit follows.
    }
}
exit 0
