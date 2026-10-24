function Get-HarnessPlatformKey {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    return $Value.Trim().ToLowerInvariant()
}

function Get-HarnessStackProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir
    )

    $profile = Get-ProjectProfile -RootDir $RootDir
    $project = Get-ProjectObjectProperty -Object $profile -Name "project"
    $language = [string](Get-ProjectObjectProperty -Object $project -Name "language")
    $framework = [string](Get-ProjectObjectProperty -Object $project -Name "framework")
    $languageKey = Get-HarnessPlatformKey -Value $language
    $frameworkKey = Get-HarnessPlatformKey -Value $framework

    $features = [ordered]@{
        "ghcr.io/devcontainers/features/common-utils:2" = @{}
        "ghcr.io/devcontainers/features/powershell:1" = @{}
        "ghcr.io/devcontainers/features/github-cli:1" = @{}
    }
    $extensions = New-Object System.Collections.Generic.List[string]
    $tools = New-Object System.Collections.Generic.List[string]
    $cachePaths = New-Object System.Collections.Generic.List[string]
    $matrix = New-Object System.Collections.Generic.List[object]

    $image = "mcr.microsoft.com/devcontainers/base:ubuntu-24.04"
    $runtime = "generic"
    $runtimeVersion = "default"
    $setupKind = "none"
    $releaseArtifactPath = "harness/release-artifacts/*"

    switch -Regex ($languageKey) {
        "^(c|c11|cpp|c\+\+)$" {
            $runtime = "c-cpp"
            $setupKind = "system"
            $features["ghcr.io/devcontainers/features/cmake:1"] = @{}
            $tools.Add("build-essential") | Out-Null
            $tools.Add("make") | Out-Null
            $tools.Add("cmake") | Out-Null
            $cachePaths.Add("~/.cache/ccache") | Out-Null
            $cachePaths.Add("build") | Out-Null
            $extensions.Add("ms-vscode.cpptools") | Out-Null
            break
        }
        "^(node|javascript|typescript|ts|js)$" {
            $runtime = "node"
            $runtimeVersion = "22"
            $setupKind = "node"
            $features["ghcr.io/devcontainers/features/node:1"] = @{ version = $runtimeVersion }
            $tools.Add("node") | Out-Null
            $tools.Add("npm") | Out-Null
            $cachePaths.Add("~/.npm") | Out-Null
            $extensions.Add("dbaeumer.vscode-eslint") | Out-Null
            break
        }
        "^python" {
            $runtime = "python"
            $runtimeVersion = "3.12"
            $setupKind = "python"
            $features["ghcr.io/devcontainers/features/python:1"] = @{ version = $runtimeVersion }
            $tools.Add("python") | Out-Null
            $tools.Add("pip") | Out-Null
            $cachePaths.Add("~/.cache/pip") | Out-Null
            $extensions.Add("ms-python.python") | Out-Null
            break
        }
        "^(java|kotlin)$" {
            $runtime = "java"
            $runtimeVersion = "21"
            $setupKind = $(if ($frameworkKey -eq "maven") { "java-maven" } else { "java-gradle" })
            $features["ghcr.io/devcontainers/features/java:1"] = @{ version = $runtimeVersion; installMaven = "true"; installGradle = "true" }
            $tools.Add("java") | Out-Null
            $tools.Add("maven") | Out-Null
            $tools.Add("gradle") | Out-Null
            $cachePaths.Add("~/.m2/repository") | Out-Null
            $cachePaths.Add("~/.gradle/caches") | Out-Null
            $cachePaths.Add("~/.gradle/wrapper") | Out-Null
            $extensions.Add("vscjava.vscode-java-pack") | Out-Null
            break
        }
        "^(dotnet|c#|csharp)$" {
            $runtime = "dotnet"
            $runtimeVersion = "8.0.x"
            $setupKind = "dotnet"
            $features["ghcr.io/devcontainers/features/dotnet:2"] = @{ version = "8.0" }
            $tools.Add("dotnet") | Out-Null
            $cachePaths.Add("~/.nuget/packages") | Out-Null
            $extensions.Add("ms-dotnettools.csharp") | Out-Null
            break
        }
        "^(go|golang)$" {
            $runtime = "go"
            $runtimeVersion = "stable"
            $setupKind = "go"
            $features["ghcr.io/devcontainers/features/go:1"] = @{}
            $tools.Add("go") | Out-Null
            $cachePaths.Add("~/go/pkg/mod") | Out-Null
            $cachePaths.Add("~/.cache/go-build") | Out-Null
            $extensions.Add("golang.go") | Out-Null
            break
        }
        "^rust" {
            $runtime = "rust"
            $runtimeVersion = "stable"
            $setupKind = "rust"
            $features["ghcr.io/devcontainers/features/rust:1"] = @{}
            $tools.Add("rustc") | Out-Null
            $tools.Add("cargo") | Out-Null
            $cachePaths.Add("~/.cargo/registry") | Out-Null
            $cachePaths.Add("~/.cargo/git") | Out-Null
            $cachePaths.Add("target") | Out-Null
            $extensions.Add("rust-lang.rust-analyzer") | Out-Null
            break
        }
        default {
            $tools.Add("git") | Out-Null
            $cachePaths.Add("~/.cache") | Out-Null
        }
    }

    $matrix.Add([ordered]@{
            os = "ubuntu-latest"
            runtime = $runtime
            runtime_version = $runtimeVersion
            setup = $setupKind
        }) | Out-Null

    return [pscustomobject]@{
        Language = $language
        Framework = $framework
        LanguageKey = $languageKey
        FrameworkKey = $frameworkKey
        Image = $image
        Runtime = $runtime
        RuntimeVersion = $runtimeVersion
        SetupKind = $setupKind
        Features = $features
        Extensions = $extensions.ToArray()
        Tools = $tools.ToArray()
        CachePaths = $cachePaths.ToArray()
        Matrix = $matrix.ToArray()
        ReleaseArtifactPath = $releaseArtifactPath
    }
}

function New-HarnessToolchainManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir
    )

    $stack = Get-HarnessStackProfile -RootDir $RootDir
    return [ordered]@{
        version = 1
        generated_by = "harness"
        dev_environment = [ordered]@{
            devcontainer = ".devcontainer/devcontainer.json"
            image = $stack.Image
            features = @($stack.Features.Keys)
            post_create_command = "sh harness/scripts/setup_portable_runtime.sh"
        }
        project = [ordered]@{
            language = $stack.Language
            framework = $stack.Framework
            runtime = $stack.Runtime
            runtime_version = $stack.RuntimeVersion
        }
        tools = @($stack.Tools)
        ci = [ordered]@{
            workflow = ".github/workflows/harness-ci.yml"
            matrix = @($stack.Matrix)
            cache_paths = @($stack.CachePaths)
            required_check = "Harness CI"
        }
        services = [ordered]@{
            contract = "harness/project/configs/service_contract.json"
            compose = "docker-compose.harness.yml"
        }
        release = [ordered]@{
            workflow = ".github/workflows/harness-release-provenance.yml"
            artifact_path = $stack.ReleaseArtifactPath
        }
    }
}

function Format-HarnessYamlList {
    param(
        [string[]]$Items,
        [int]$Indent = 0
    )

    $prefix = " " * $Indent
    if ($Items.Count -eq 0) {
        return ($prefix + "[]")
    }

    return (($Items | ForEach-Object { $prefix + "- " + $_ }) -join [Environment]::NewLine)
}

function Get-HarnessCiMatrixYaml {
    param(
        [Parameter(Mandatory = $true)]
        $Stack
    )

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($Stack.Matrix)) {
        $lines.Add("          - os: $($entry.os)") | Out-Null
        $lines.Add("            runtime: $($entry.runtime)") | Out-Null
        $lines.Add("            runtime_version: `"$($entry.runtime_version)`"") | Out-Null
        $lines.Add("            setup: $($entry.setup)") | Out-Null
    }

    return ($lines.ToArray() -join [Environment]::NewLine)
}

function Get-HarnessCachePathsYaml {
    param(
        [Parameter(Mandatory = $true)]
        $Stack
    )

    if ($Stack.CachePaths.Count -eq 0) {
        return "            ~/.cache"
    }

    return (($Stack.CachePaths | ForEach-Object { "            " + [string]$_ }) -join [Environment]::NewLine)
}

function Get-HarnessCiSetupStepsYaml {
    param(
        [Parameter(Mandatory = $true)]
        $Stack
    )

    switch ([string]$Stack.SetupKind) {
        "node" {
            return @'
      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version: ${{ matrix.runtime_version }}
'@
        }
        "python" {
            return @'
      - name: Setup Python
        uses: actions/setup-python@v5
        with:
          python-version: ${{ matrix.runtime_version }}
'@
        }
        "java-gradle" {
            return @'
      - name: Setup Java
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: ${{ matrix.runtime_version }}
          cache: gradle
'@
        }
        "java-maven" {
            return @'
      - name: Setup Java
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: ${{ matrix.runtime_version }}
          cache: maven
'@
        }
        "dotnet" {
            return @'
      - name: Setup .NET
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: ${{ matrix.runtime_version }}
'@
        }
        "go" {
            return @'
      - name: Setup Go
        uses: actions/setup-go@v5
        with:
          go-version: ${{ matrix.runtime_version }}
'@
        }
        "rust" {
            return @'
      - name: Setup Rust
        shell: bash
        run: rustup toolchain install stable --profile minimal
'@
        }
        default {
            return @'
      - name: Setup system runtime
        shell: bash
        run: |
          echo "Using runner-provided system runtime for ${{ matrix.runtime }}"
'@
        }
    }
}

function Write-HarnessReportFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir,
        [Parameter(Mandatory = $true)]
        [string]$FileName,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $reportsDir = Resolve-HarnessEnginePath -RootDir $RootDir -ProjectPath "harness/reports" -Label "harness.reports"
    Ensure-HarnessDirectory -Path $reportsDir
    $path = Join-Path $reportsDir $FileName
    Write-Utf8File -Path $path -Content $Content
    return $path
}
