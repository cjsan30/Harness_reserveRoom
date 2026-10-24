param(
    [ValidateSet("none", "postgres", "redis", "postgres-redis", "mysql")]
    [string]$Preset = "none",
    [switch]$Force,
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")

$rootDir = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    Get-HarnessRoot -ScriptDirectory $PSScriptRoot
} else {
    [System.IO.Path]::GetFullPath($RepositoryRoot)
}

function New-ServiceDefinition {
    param([string]$Id)

    switch ($Id) {
        "postgres" {
            return [ordered]@{
                id = "postgres"
                image = "postgres:16"
                ports = @("5432:5432")
                env = [ordered]@{
                    POSTGRES_DB = "harness_test"
                    POSTGRES_USER = "harness"
                    POSTGRES_HOST_AUTH_METHOD = "trust"
                }
                healthcheck = "pg_isready -U harness -d harness_test"
            }
        }
        "redis" {
            return [ordered]@{
                id = "redis"
                image = "redis:7"
                ports = @("6379:6379")
                env = [ordered]@{}
                healthcheck = "redis-cli ping"
            }
        }
        "mysql" {
            return [ordered]@{
                id = "mysql"
                image = "mysql:8"
                ports = @("3306:3306")
                env = [ordered]@{
                    MYSQL_DATABASE = "harness_test"
                    MYSQL_ALLOW_EMPTY_PASSWORD = "yes"
                }
                healthcheck = "mysqladmin ping -h 127.0.0.1"
            }
        }
    }
}

function Get-ServiceEnvEntries {
    param($EnvObject)

    $entries = New-Object System.Collections.Generic.List[object]
    if ($null -eq $EnvObject) {
        return $entries.ToArray()
    }

    if ($EnvObject -is [System.Collections.IDictionary]) {
        foreach ($key in $EnvObject.Keys) {
            $entries.Add([pscustomobject]@{ Name = [string]$key; Value = [string]$EnvObject[$key] }) | Out-Null
        }
        return $entries.ToArray()
    }

    foreach ($property in @($EnvObject.PSObject.Properties)) {
        $entries.Add([pscustomobject]@{ Name = [string]$property.Name; Value = [string]$property.Value }) | Out-Null
    }

    return $entries.ToArray()
}

$services = New-Object System.Collections.Generic.List[object]
switch ($Preset) {
    "postgres" { $services.Add((New-ServiceDefinition -Id "postgres")) | Out-Null }
    "redis" { $services.Add((New-ServiceDefinition -Id "redis")) | Out-Null }
    "postgres-redis" {
        $services.Add((New-ServiceDefinition -Id "postgres")) | Out-Null
        $services.Add((New-ServiceDefinition -Id "redis")) | Out-Null
    }
    "mysql" { $services.Add((New-ServiceDefinition -Id "mysql")) | Out-Null }
}

$contractPath = Resolve-HarnessEnginePath -RootDir $rootDir -ProjectPath "harness/project/configs/service_contract.json" -Label "service contract"
$docPath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath "docs/service_contract.md" -Label "service contract doc"
$composePath = Resolve-ProjectPath -RootDir $rootDir -ProjectPath "docker-compose.harness.yml" -Label "service compose"

foreach ($path in @($contractPath, $docPath)) {
    if ((Test-Path -LiteralPath $path) -and -not $Force) {
        throw "file already exists: $(Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $path); rerun with -Force to overwrite"
    }
}
if ($services.Count -gt 0 -and (Test-Path -LiteralPath $composePath) -and -not $Force) {
    throw "file already exists: docker-compose.harness.yml; rerun with -Force to overwrite"
}

Ensure-HarnessDirectory -Path (Split-Path -Parent $contractPath)
Ensure-HarnessDirectory -Path (Split-Path -Parent $docPath)

$contract = [ordered]@{
    version = 1
    mode = $(if ($services.Count -eq 0) { "none" } else { "docker-compose" })
    preset = $Preset
    compose_file = $(if ($services.Count -eq 0) { "" } else { "docker-compose.harness.yml" })
    services = $services.ToArray()
    readiness = [ordered]@{
        command = $(if ($services.Count -eq 0) { "none" } else { "docker compose -f docker-compose.harness.yml up -d --wait" })
        timeout_seconds = 60
    }
    notes = @(
        "Local service values are for disposable development and CI only.",
        "Do not put production credentials in this file."
    )
}
Write-Utf8File -Path $contractPath -Content ($contract | ConvertTo-Json -Depth 20)

if ($services.Count -gt 0) {
    $composeLines = New-Object System.Collections.Generic.List[string]
    $composeLines.Add("name: harness-services") | Out-Null
    $composeLines.Add("services:") | Out-Null
    foreach ($service in $services) {
        $composeLines.Add("  $($service.id):") | Out-Null
        $composeLines.Add("    image: $($service.image)") | Out-Null
        if (@($service.ports).Count -gt 0) {
            $composeLines.Add("    ports:") | Out-Null
            foreach ($port in @($service.ports)) {
                $composeLines.Add("      - `"$port`"") | Out-Null
            }
        }
        $envEntries = @(Get-ServiceEnvEntries -EnvObject $service.env)
        if ($envEntries.Count -gt 0) {
            $composeLines.Add("    environment:") | Out-Null
            foreach ($property in $envEntries) {
                $composeLines.Add("      $($property.Name): `"$($property.Value)`"") | Out-Null
            }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$service.healthcheck)) {
            $composeLines.Add("    healthcheck:") | Out-Null
            $composeLines.Add("      test: [ `"CMD-SHELL`", `"$($service.healthcheck)`" ]") | Out-Null
            $composeLines.Add("      interval: 5s") | Out-Null
            $composeLines.Add("      timeout: 5s") | Out-Null
            $composeLines.Add("      retries: 12") | Out-Null
        }
    }
    Write-Utf8File -Path $composePath -Content ($composeLines.ToArray() -join [Environment]::NewLine)
}

$serviceLines = if ($services.Count -eq 0) {
    "- none"
} else {
    ($services.ToArray() | ForEach-Object { "- $($_.id): $($_.image)" }) -join [Environment]::NewLine
}
$doc = @"
# Service Contract

## Summary

- preset: $Preset
- mode: $($contract.mode)
- compose_file: $($contract.compose_file)

## Services

$serviceLines

## Rules

- Use only disposable local or CI credentials here.
- Store real production credentials outside Git.
- Start services with `pwsh -NoProfile -File harness/scripts/run_service_contract.ps1 -Action up`.
- Stop services with `pwsh -NoProfile -File harness/scripts/run_service_contract.ps1 -Action down`.
"@
Write-Utf8File -Path $docPath -Content $doc

Write-Output "service_contract: $contractPath"
Write-Output "service_doc: $docPath"
if ($services.Count -gt 0) {
    Write-Output "compose: $composePath"
}
