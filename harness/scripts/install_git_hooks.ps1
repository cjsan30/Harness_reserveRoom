param(
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
. (Join-Path $PSScriptRoot "git_workflow_common.ps1")

$rootDir = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Get-HarnessRoot -ScriptDirectory $PSScriptRoot
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}

$hooksPath = Get-GitWorkflowResolvedPath -RootDir $rootDir -Name "hooks_path"
$portableHooksPath = $null
foreach ($candidateRelativePath in @("harness/githooks", "githooks")) {
    $candidatePath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath $candidateRelativePath -Label "portable hooks path"
    if (Test-Path -LiteralPath $candidatePath -PathType Container) {
        $portableHooksPath = $candidatePath
        break
    }
}
if ([string]::IsNullOrWhiteSpace($portableHooksPath)) {
    throw "required hook template directory is missing: harness/githooks or githooks"
}
Ensure-HarnessDirectory -Path $hooksPath
$bootstrapSource = Join-Path $PSScriptRoot 'hook_bootstrap.sh'
Write-Utf8File (Join-Path $hooksPath 'harness-bootstrap.sh') ([IO.File]::ReadAllText($bootstrapSource).Replace("`r`n", "`n"))

foreach ($hookName in @("pre-commit", "pre-push", "pre-merge-commit", "pre-rebase")) {
    $hookPath = Join-Path $hooksPath $hookName
    $portableHookPath = Join-Path $portableHooksPath $hookName
    if (-not (Test-Path -LiteralPath $portableHookPath)) {
        throw "required hook template is missing: $portableHookPath"
    }

    $shouldCopy = $true
    if (Test-Path -LiteralPath $hookPath) {
        $currentContent = Get-Content -Raw -LiteralPath $hookPath
        $templateContent = Get-Content -Raw -LiteralPath $portableHookPath
        $shouldCopy = ($currentContent -ne $templateContent)
    }

    if ($shouldCopy) {
        $templateContent = [IO.File]::ReadAllText($portableHookPath).Replace("`r`n", "`n")
        Write-Utf8File -Path $hookPath -Content $templateContent
    }

    if (-not (Test-HarnessIsWindows) -and $null -ne (Get-Command chmod -ErrorAction SilentlyContinue)) {
        Invoke-HarnessProcess -Executable "chmod" -Arguments @("+x", $hookPath) -AllowFailure | Out-Null
    }
}

try {
    $resolverPath = Resolve-HarnessEnginePath -RootDir $rootDir -ProjectPath "harness/scripts/resolve_powershell.sh" -Label "PowerShell resolver"
    if (-not (Test-Path -LiteralPath $resolverPath)) {
        $resolverPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath "scripts/resolve_powershell.sh" -Label "PowerShell resolver"
    }
} catch {
    $resolverPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath "scripts/resolve_powershell.sh" -Label "PowerShell resolver"
}
if (-not (Test-HarnessIsWindows) -and (Test-Path -LiteralPath $resolverPath) -and $null -ne (Get-Command chmod -ErrorAction SilentlyContinue)) {
    Invoke-HarnessProcess -Executable "chmod" -Arguments @("+x", $resolverPath) -AllowFailure | Out-Null
}

try {
    $pathCommonPath = Resolve-HarnessEnginePath -RootDir $rootDir -ProjectPath "harness/scripts/path_common.sh" -Label "path common helper"
    if (-not (Test-Path -LiteralPath $pathCommonPath)) {
        $pathCommonPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath "scripts/path_common.sh" -Label "path common helper"
    }
} catch {
    $pathCommonPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath "scripts/path_common.sh" -Label "path common helper"
}
if (-not (Test-HarnessIsWindows) -and (Test-Path -LiteralPath $pathCommonPath) -and $null -ne (Get-Command chmod -ErrorAction SilentlyContinue)) {
    Invoke-HarnessProcess -Executable "chmod" -Arguments @("+x", $pathCommonPath) -AllowFailure | Out-Null
}

$absoluteHooksPath = [System.IO.Path]::GetFullPath($hooksPath)
Invoke-GitCommand -RootDir $rootDir -Arguments @("config", "--local", "core.hooksPath", $absoluteHooksPath) | Out-Null

Write-Output "hooks_path: $hooksPath"
Write-Output "git_config_core_hooksPath: $absoluteHooksPath"
