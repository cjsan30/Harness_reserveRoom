param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("feature", "integration", "final")]
    [string]$Stage
)

# Git gate command for the engine repository itself (.harness/self_workflow.json).
# feature:     syntax and JSON checks on every required PowerShell runtime (seconds)
# integration: full self regression on every required runtime
# final:       integration plus the dashboard HTTP regression
# A required runtime that cannot be found is a failure, never a skip.

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")

$engineRoot = Split-Path -Parent $PSScriptRoot

# Gate context from run_git_gate must not leak into the isolated regression fixtures.
foreach ($name in @("CODEX_ACTIVE_GIT_GATE_STAGE", "CODEX_HARNESS_ROOT", "CODEX_GIT_WORKSPACE_ROOT")) {
    [Environment]::SetEnvironmentVariable($name, $null, "Process")
}

function Find-SelfGateExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string[]]$Candidates = @()
    )

    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }

    foreach ($candidate in $Candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    return $null
}

$runtimes = New-Object System.Collections.Generic.List[object]
if (Test-HarnessIsWindows) {
    $windowsPowerShell = Find-SelfGateExecutable -Name "powershell.exe" -Candidates @(
        (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe")
    )
    $runtimes.Add([pscustomobject]@{ Label = "Windows PowerShell 5.1"; Path = $windowsPowerShell; Arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass") }) | Out-Null
    $pwsh = Find-SelfGateExecutable -Name "pwsh.exe" -Candidates @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\pwsh.exe"),
        (Join-Path $env:ProgramFiles "PowerShell\7\pwsh.exe")
    )
    $runtimes.Add([pscustomobject]@{ Label = "PowerShell 7"; Path = $pwsh; Arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass") }) | Out-Null
} else {
    $pwsh = Find-SelfGateExecutable -Name "pwsh"
    $runtimes.Add([pscustomobject]@{ Label = "PowerShell 7"; Path = $pwsh; Arguments = @("-NoProfile") }) | Out-Null
}

$failures = New-Object System.Collections.Generic.List[string]
foreach ($runtime in $runtimes) {
    if ([string]::IsNullOrWhiteSpace($runtime.Path)) {
        $failures.Add("$($runtime.Label): runtime not found") | Out-Null
    }
}
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Output "FAIL $_" }
    exit 1
}

$regressionArguments = @("-File", (Join-Path $PSScriptRoot "test_harness.ps1"))
if ($Stage -eq "feature") {
    $regressionArguments += "-SyntaxOnly"
}

foreach ($runtime in $runtimes) {
    Write-Output "== $Stage gate: $($runtime.Label) ($($runtime.Path))"
    $result = Invoke-HarnessProcess -Executable $runtime.Path -Arguments (@($runtime.Arguments) + $regressionArguments) -WorkingDirectory $engineRoot -AllowFailure
    Write-Output $result.Output
    if (-not $result.Success) {
        $failures.Add("$($runtime.Label): self regression failed (exit $($result.ExitCode))") | Out-Null
    }
}

if ($Stage -eq "final") {
    $python = Find-SelfGateExecutable -Name "python"
    if ([string]::IsNullOrWhiteSpace($python)) {
        $python = Find-SelfGateExecutable -Name "python3"
    }

    if ([string]::IsNullOrWhiteSpace($python)) {
        $failures.Add("Python: runtime not found for the dashboard HTTP regression") | Out-Null
    } else {
        Write-Output "== final gate: dashboard HTTP regression ($python)"
        $result = Invoke-HarnessProcess -Executable $python -Arguments @("-B", (Join-Path $PSScriptRoot "test_harness_dashboard_server.py")) -WorkingDirectory $engineRoot -AllowFailure
        Write-Output $result.Output
        if (-not $result.Success) {
            $failures.Add("dashboard HTTP regression failed (exit $($result.ExitCode))") | Out-Null
        }
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Output "FAIL $_" }
    exit 1
}

Write-Output "PASS $Stage self gate"
exit 0
