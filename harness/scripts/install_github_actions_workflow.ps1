param(
    [string]$WorkflowPath = ".github/workflows/harness-ci.yml",
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

$targetPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath $WorkflowPath -Label "github actions workflow"
if ((Test-Path -LiteralPath $targetPath) -and -not $Force) {
    throw "workflow already exists: $WorkflowPath; rerun with -Force to overwrite"
}

$targetDir = Split-Path -Parent $targetPath
Ensure-HarnessDirectory -Path $targetDir

$stack = Get-HarnessStackProfile -RootDir $rootDir
$matrixYaml = Get-HarnessCiMatrixYaml -Stack $stack
$cachePathsYaml = Get-HarnessCachePathsYaml -Stack $stack
$setupStepsYaml = Get-HarnessCiSetupStepsYaml -Stack $stack

$template = @'
name: Harness CI

on:
  pull_request:
    branches:
      - main
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: harness-ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  harness-matrix:
    name: Harness Matrix (${{ matrix.os }}, ${{ matrix.runtime }})
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        include:
__MATRIX__
    steps:
      - name: Checkout
        uses: actions/checkout@v6

__SETUP_STEPS__

      - name: Verify PowerShell
        shell: bash
        run: pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'

      - name: Cache harness dependencies
        uses: actions/cache@v4
        with:
          path: |
__CACHE_PATHS__
          key: ${{ runner.os }}-harness-${{ matrix.runtime }}-${{ hashFiles('**/package-lock.json', '**/pnpm-lock.yaml', '**/yarn.lock', '**/requirements*.txt', '**/pyproject.toml', '**/poetry.lock', '**/pom.xml', '**/build.gradle*', '**/gradle.lockfile', '**/packages.lock.json', '**/go.sum', '**/Cargo.lock', '**/Makefile', '**/CMakeLists.txt') }}
          restore-keys: |
            ${{ runner.os }}-harness-${{ matrix.runtime }}-
            ${{ runner.os }}-harness-

      - name: Setup portable harness runtime
        shell: bash
        env:
          HARNESS_CI_MODE: "true"
        run: sh harness/scripts/setup_portable_runtime.sh

      - name: Start service dependencies
        shell: bash
        run: |
          if [ -f docker-compose.harness.yml ]; then
            docker compose -f docker-compose.harness.yml up -d --wait
          else
            echo "no service contract compose file"
          fi

      - name: Run harness full cycle
        shell: bash
        env:
          HARNESS_CI_MODE: "true"
        run: pwsh -NoProfile -File harness/scripts/run_harness_cycle.ps1 -SkipRetryPrompt

      - name: Stop service dependencies
        if: always()
        shell: bash
        run: |
          if [ -f docker-compose.harness.yml ]; then
            docker compose -f docker-compose.harness.yml down --remove-orphans
          fi

  harness:
    name: Harness CI
    runs-on: ubuntu-latest
    needs: harness-matrix
    if: always()
    steps:
      - name: Verify matrix result
        shell: bash
        run: |
          if [ "${{ needs.harness-matrix.result }}" != "success" ]; then
            echo "Harness matrix failed: ${{ needs.harness-matrix.result }}"
            exit 1
          fi
          echo "Harness matrix passed"
'@

$template = Convert-HarnessLayoutText $rootDir $template
$content = $template.Replace("__MATRIX__", $matrixYaml).Replace("__CACHE_PATHS__", $cachePathsYaml).Replace("__SETUP_STEPS__", $setupStepsYaml.TrimEnd())

Write-Utf8File -Path $targetPath -Content $content
Write-Output "workflow: $targetPath"
