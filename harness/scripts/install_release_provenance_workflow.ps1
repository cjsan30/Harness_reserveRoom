param(
    [string]$WorkflowPath = ".github/workflows/harness-release-provenance.yml",
    [string]$ArtifactPath = "harness/release-artifacts/*",
    [switch]$Force,
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

$releaseCommand = Get-ProjectCommand -RootDir $rootDir -Name "release" -Fallback "make"
$targetPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath $WorkflowPath -Label "release provenance workflow"
if ((Test-Path -LiteralPath $targetPath) -and -not $Force) {
    throw "workflow already exists: $WorkflowPath; rerun with -Force to overwrite"
}
Ensure-HarnessDirectory -Path (Split-Path -Parent $targetPath)

$template = @'
name: Harness Release Provenance

on:
  workflow_dispatch:
  release:
    types:
      - published

permissions:
  contents: read
  id-token: write
  attestations: write

jobs:
  release-provenance:
    name: Harness Release Provenance
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v6

      - name: Verify PowerShell
        shell: bash
        run: pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'

      - name: Setup portable harness runtime
        shell: bash
        env:
          HARNESS_CI_MODE: "true"
        run: sh harness/scripts/setup_portable_runtime.sh

      - name: Run release command
        shell: bash
        run: |
          set -euo pipefail
          mkdir -p harness/release-artifacts
          __RELEASE_COMMAND__
          if [ -d dist ]; then cp -R dist harness/release-artifacts/dist; fi
          if [ -d build ]; then cp -R build harness/release-artifacts/build; fi
          if ! find harness/release-artifacts -type f | grep -q .; then
            tar -czf harness/release-artifacts/source-snapshot.tar.gz --exclude=.git --exclude=harness/reports --exclude=harness/state .
          fi

      - name: Upload release artifacts
        uses: actions/upload-artifact@v4
        with:
          name: harness-release-artifacts
          path: harness/release-artifacts

      - name: Generate artifact attestation
        uses: actions/attest@v4
        with:
          subject-path: '__ARTIFACT_PATH__'
'@

$template = Convert-HarnessLayoutText $rootDir $template
$ArtifactPath = Convert-HarnessLayoutPath $rootDir $ArtifactPath
$content = $template.Replace("__RELEASE_COMMAND__", $releaseCommand).Replace("__ARTIFACT_PATH__", $ArtifactPath)
Write-Utf8File -Path $targetPath -Content $content
Write-Output "workflow: $targetPath"
