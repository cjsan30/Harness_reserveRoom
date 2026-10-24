param(
    [ValidateSet("status", "up", "down")]
    [string]$Action = "status",
    [switch]$DryRun,
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")

$rootDir = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Get-HarnessRoot -ScriptDirectory $PSScriptRoot
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}

$composePath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath "docker-compose.harness.yml" -Label "service compose"
if (-not (Test-Path -LiteralPath $composePath)) {
    Write-Output "status: no_services"
    Write-Output "detail: docker-compose.harness.yml is missing"
    exit 0
}

switch ($Action) {
    "up" { $arguments = @("compose", "-f", $composePath, "up", "-d", "--wait") }
    "down" { $arguments = @("compose", "-f", $composePath, "down", "--remove-orphans") }
    default { $arguments = @("compose", "-f", $composePath, "ps") }
}

if ($DryRun) {
    Write-Output "status: dry_run"
    Write-Output "command: docker $($arguments -join ' ')"
    exit 0
}

$result = Invoke-HarnessProcess -Executable "docker" -Arguments $arguments -WorkingDirectory $rootDir -AllowFailure
Write-Output $result.Output
if (-not $result.Success) {
    throw "docker service contract command failed: docker $($arguments -join ' ')"
}

Write-Output "status: pass"
