param([switch]$SyntaxOnly)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object 'System.Collections.Generic.List[string]'
$scripts = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)
foreach ($file in $scripts) {
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    foreach ($parseIssue in $errors) { $failures.Add("$($file.Name):$($parseIssue.Extent.StartLineNumber) $($parseIssue.Message)") }
}
foreach ($directory in @('configs', 'project', '.harness')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $directory) -PathType Container)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root $directory) -Filter '*.json' -File -Recurse -Force)) {
        try { Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName | ConvertFrom-Json | Out-Null }
        catch { $failures.Add("invalid JSON: $($file.FullName)") }
    }
}
if ($failures.Count -gt 0) { $failures | Write-Output; exit 1 }
Write-Output "Syntax: $($scripts.Count) PowerShell scripts and configuration JSON passed"
if ($SyntaxOnly) { exit 0 }
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$failed = $false
foreach ($suite in @('test_harness_safety.ps1', 'test_harness_recovery.ps1', 'test_execution_usage.ps1', 'test_failure_policy.ps1', 'test_environment_repair.ps1', 'test_notifications.ps1', 'test_assignment_evidence.ps1', 'test_harness_layout.ps1', 'test_harness_cli.ps1', 'test_provider_contract.ps1', 'test_provider_claude.ps1', 'test_harness_shell.ps1', 'test_harness_dashboard.ps1', 'test_git_workflow_policy.ps1', 'test_project_adapter.ps1')) {
    $result = Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot $suite) -AllowFailure
    Write-Output $result.Output
    if (-not $result.Success) { $failed = $true }
    if ($suite -eq 'test_harness_shell.ps1' -and $result.Success) {
        $fixtureMatch = [regex]::Match($result.Output, 'Shell results: 36/36 passed; artifacts: ([^\r\n]+)')
        if (-not $fixtureMatch.Success) { throw 'shell fixture path missing for entrypoint regression' }
        $entryResult = Invoke-HarnessPowerShellFile -FilePath (Join-Path $PSScriptRoot 'test_harness_entrypoints.ps1') -Arguments @('-FixtureDirectory', $fixtureMatch.Groups[1].Value) -AllowFailure
        Write-Output $entryResult.Output
        if (-not $entryResult.Success) { $failed = $true }
    }
}
if ($failed) { exit 1 }
exit 0
