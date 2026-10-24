$script:GitHubPrJsonFields = "number,url,state,isDraft,headRefName,headRefOid,baseRefName,baseRefOid,mergeStateStatus,mergeable,reviewDecision,title"

function Get-GitHubCliExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir
    )

    $explicitPath = [Environment]::GetEnvironmentVariable("HARNESS_GH_PATH", "Process")
    if (-not [string]::IsNullOrWhiteSpace($explicitPath) -and (Test-Path -LiteralPath $explicitPath)) {
        return [System.IO.Path]::GetFullPath($explicitPath)
    }

    $command = Get-Command "gh" -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $homeDir = [Environment]::GetFolderPath("UserProfile")
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($homeDir)) {
        $candidates.Add((Join-Path $homeDir ".local/bin/gh")) | Out-Null
        $candidates.Add((Join-Path $homeDir ".local/bin/gh.exe")) | Out-Null
    }
    $candidates.Add((Join-Path $RootDir "tools/gh/bin/gh")) | Out-Null
    $candidates.Add((Join-Path $RootDir "harness/tools/gh/bin/gh")) | Out-Null

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    throw "GitHub CLI 'gh' was not found. Install gh or set HARNESS_GH_PATH."
}

function Invoke-GitHubCli {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $gh = Get-GitHubCliExecutable -RootDir $RootDir
    $result = Invoke-HarnessProcess -Executable $gh -Arguments $Arguments -WorkingDirectory $RootDir -AllowFailure
    if (-not $AllowFailure -and -not $result.Success) {
        throw "gh command failed: gh $($Arguments -join ' ')`n$($result.Output)"
    }

    return $result
}

function Assert-GitHubCliAuthenticated {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir
    )

    $result = Invoke-GitHubCli -RootDir $RootDir -Arguments @("auth", "status", "--active") -AllowFailure
    if (-not $result.Success) {
        throw "gh is not authenticated. Run: gh auth login"
    }
}

function Convert-GitHubJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$JsonText,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        throw "$Label returned empty JSON"
    }

    try {
        return ($JsonText | ConvertFrom-Json)
    } catch {
        throw "failed to parse $Label JSON: $($_.Exception.Message)"
    }
}

function Get-GitHubPullRequestView {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir,
        [Parameter(Mandatory = $true)]
        [string]$Selector,
        [switch]$AllowMissing
    )

    $result = Invoke-GitHubCli -RootDir $RootDir -Arguments @("pr", "view", $Selector, "--json", $script:GitHubPrJsonFields) -AllowFailure
    if (-not $result.Success) {
        if ($AllowMissing) {
            return $null
        }
        throw "unable to view pull request '$Selector':`n$($result.Output)"
    }

    return Convert-GitHubJson -JsonText $result.Output -Label "gh pr view"
}

function Get-GitHubPullRequestChecks {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir,
        [Parameter(Mandatory = $true)]
        [string]$Selector,
        [switch]$RequiredOnly
    )

    $arguments = @("pr", "checks", $Selector, "--json", "name,state,bucket,workflow,link,startedAt,completedAt")
    if ($RequiredOnly) {
        $arguments += "--required"
    }

    $result = Invoke-GitHubCli -RootDir $RootDir -Arguments $arguments -AllowFailure
    if (-not $result.Success -and [string]::IsNullOrWhiteSpace($result.Output)) {
        throw "unable to read pull request checks for '$Selector':`n$($result.Output)"
    }

    if ([string]::IsNullOrWhiteSpace($result.Output)) {
        return @()
    }

    $parsed = Convert-GitHubJson -JsonText $result.Output -Label "gh pr checks"
    return @($parsed)
}

function Get-GitHubChecksStatus {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Checks,
        [switch]$AllowNoChecks
    )

    if ($Checks.Count -eq 0) {
        return [pscustomobject]@{
            Status = $(if ($AllowNoChecks) { "pass" } else { "no_required_checks" })
            Pass = 0
            Fail = 0
            Pending = 0
            Other = 0
        }
    }

    $fail = 0
    $pending = 0
    $pass = 0
    $other = 0
    foreach ($check in $Checks) {
        switch ([string]$check.bucket) {
            "pass" { $pass++ }
            "fail" { $fail++ }
            "cancel" { $fail++ }
            "pending" { $pending++ }
            default { $other++ }
        }
    }

    $status = "pass"
    if ($fail -gt 0) {
        $status = "fail"
    } elseif ($pending -gt 0 -or $other -gt 0) {
        $status = "pending"
    }

    return [pscustomobject]@{
        Status = $status
        Pass = $pass
        Fail = $fail
        Pending = $pending
        Other = $other
    }
}
