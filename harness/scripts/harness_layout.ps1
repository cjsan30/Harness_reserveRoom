# RootDir always means the target repository; engine paths are resolved separately.
function Get-HarnessEngineRoot {
    param([Parameter(Mandatory=$true)][string]$RootDir)
    $root = [IO.Path]::GetFullPath($RootDir)
    $standalone = Test-Path -LiteralPath (Join-Path $root 'scripts/harness_common.ps1')
    $nested = Test-Path -LiteralPath (Join-Path $root 'harness/scripts/harness_common.ps1')
    if ($standalone -and $nested) { throw 'ambiguous Harness layout: both root/scripts and harness/scripts exist' }
    if ($standalone) { return $root }
    # A profile-only target is also used by diagnostics and isolated state tests.
    return Join-Path $root 'harness'
}

function Convert-HarnessLayoutPath {
    param([string]$RootDir, [string]$Path)
    if ([string]::Equals((Get-HarnessEngineRoot $RootDir), [IO.Path]::GetFullPath($RootDir), (Get-HarnessPathComparison))) {
        if ($Path -match '^harness[/\\](.+)$') { return $Matches[1] }
    }
    return $Path
}

function Resolve-HarnessEnginePath {
    param([string]$RootDir, [string]$ProjectPath, [string]$Label = 'Harness path')
    $path = Convert-HarnessLayoutPath $RootDir $ProjectPath
    return Resolve-ProjectPath -RootDir $RootDir -ProjectPath $path -Label $Label
}

function Convert-HarnessLayoutText {
    param([string]$RootDir, [AllowEmptyString()][string]$Text)
    # Only generated instructions/default commands, never arbitrary intake text.
    if ([string]::Equals((Get-HarnessEngineRoot $RootDir), [IO.Path]::GetFullPath($RootDir), (Get-HarnessPathComparison))) {
        return ($Text -replace '(?<![A-Za-z0-9_./-])harness/(?=(scripts|configs|project|reports|state|assignments|docs|githooks|release-artifacts)(/|\b)|AGENT\.md)', '')
    }
    return $Text
}

function Set-HarnessProfileLayout {
    param([string]$RootDir, $Profile)
    foreach ($field in @('harness', 'git_workflow')) {
        $section = Get-ProjectObjectProperty $Profile $field
        if ($null -eq $section) { continue }
        foreach ($property in $section.PSObject.Properties) {
            if ($property.Value -is [string] -and $property.Value -match '^harness[/\\]') {
                $property.Value = Convert-HarnessLayoutPath $RootDir $property.Value
            }
        }
    }
    $commands = Get-ProjectObjectProperty $Profile 'commands'
    if ($null -ne $commands -and $null -ne $commands.PSObject.Properties['full_cycle']) {
        $commands.full_cycle = Convert-HarnessLayoutText $RootDir $commands.full_cycle
    }
    $owners = Get-ProjectObjectProperty $Profile 'owners'
    if ($null -ne $owners) {
        foreach ($property in $owners.PSObject.Properties) {
            $owner = $property.Value
            if ($null -ne $owner.PSObject.Properties['read']) { $owner.read = @($owner.read | ForEach-Object { Convert-HarnessLayoutPath $RootDir $_ } | Select-Object -Unique) }
            if ($property.Name -eq 'manager-harness') {
                $owner.validation = Convert-HarnessLayoutText $RootDir $owner.validation
                if ($owner.work_area -eq 'harness' -and (Get-HarnessEngineRoot $RootDir) -eq [IO.Path]::GetFullPath($RootDir)) { $owner.work_area = 'project-wide' }
            }
        }
    }
    return $Profile
}
