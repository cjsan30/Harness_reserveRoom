param(
    [switch]$Force,
    [switch]$IncludeMise,
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")
. (Join-Path $PSScriptRoot "platform_engineering_common.ps1")

$rootDir = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Get-HarnessRoot -ScriptDirectory $PSScriptRoot
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}

$stack = Get-HarnessStackProfile -RootDir $rootDir
$devcontainerPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath ".devcontainer/devcontainer.json" -Label "devcontainer"
$manifestPath = Resolve-HarnessEnginePath -RootDir $rootDir -ProjectPath "harness/project/configs/toolchain_manifest.json" -Label "toolchain manifest"

foreach ($path in @($devcontainerPath, $manifestPath)) {
    if ((Test-Path -LiteralPath $path) -and -not $Force) {
        throw "file already exists: $(Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $path); rerun with -Force to overwrite"
    }
}

Ensure-HarnessDirectory -Path (Split-Path -Parent $devcontainerPath)
Ensure-HarnessDirectory -Path (Split-Path -Parent $manifestPath)

$devcontainer = [ordered]@{
    name = "Harness Dev Environment"
    image = $stack.Image
    features = $stack.Features
    remoteUser = "vscode"
    postCreateCommand = (Convert-HarnessLayoutText $rootDir "sh harness/scripts/setup_portable_runtime.sh")
    customizations = [ordered]@{
        vscode = [ordered]@{
            extensions = @($stack.Extensions)
        }
    }
}

Write-Utf8File -Path $devcontainerPath -Content ($devcontainer | ConvertTo-Json -Depth 20)
Write-Utf8File -Path $manifestPath -Content (Convert-HarnessLayoutText $rootDir ((New-HarnessToolchainManifest -RootDir $rootDir) | ConvertTo-Json -Depth 20))

if ($IncludeMise) {
    $misePath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath "mise.toml" -Label "mise config"
    if ((Test-Path -LiteralPath $misePath) -and -not $Force) {
        throw "file already exists: mise.toml; rerun with -Force to overwrite"
    }

    $toolLines = New-Object System.Collections.Generic.List[string]
    switch ([string]$stack.Runtime) {
        "node" { $toolLines.Add('node = "22"') | Out-Null }
        "python" { $toolLines.Add('python = "3.12"') | Out-Null }
        "java" { $toolLines.Add('java = "temurin-21"') | Out-Null }
        "go" { $toolLines.Add('go = "latest"') | Out-Null }
        "rust" { $toolLines.Add('rust = "stable"') | Out-Null }
    }

    $toolsBlock = if ($toolLines.Count -eq 0) { "# stack-specific tools are supplied by the devcontainer" } else { $toolLines.ToArray() -join [Environment]::NewLine }
    $miseContent = @"
[tools]
$toolsBlock

[tasks.harness-preflight]
run = "pwsh -NoProfile -File harness/scripts/run_harness_preflight.ps1"

[tasks.harness-cycle]
run = "pwsh -NoProfile -File harness/scripts/run_harness_cycle.ps1"
"@
    Write-Utf8File -Path $misePath -Content (Convert-HarnessLayoutText $rootDir $miseContent)
    Write-Output "mise: $misePath"
}

Write-Output "devcontainer: $devcontainerPath"
Write-Output "toolchain_manifest: $manifestPath"
