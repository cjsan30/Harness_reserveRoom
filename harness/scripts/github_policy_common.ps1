$script:HarnessGitHubRulesetName = "Harness Main Protection"
$script:HarnessGitHubRequiredCheckName = "Harness CI"

function ConvertTo-HarnessObjectArray {
    param(
        $Value
    )

    if ($null -eq $Value) {
        return [object[]]@()
    }
    if ($Value -is [System.Array]) {
        return [object[]]$Value
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [pscustomobject]) {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) {
            $items.Add($item) | Out-Null
        }
        return $items.ToArray()
    }

    return [object[]]@($Value)
}

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir,
        [Parameter(Mandatory = $true)]
        [string]$Endpoint,
        [string]$Method = "GET",
        [string]$InputFile,
        [switch]$AllowFailure
    )

    $arguments = @("api", $Endpoint)
    if (-not [string]::IsNullOrWhiteSpace($Method)) {
        $arguments += @("--method", $Method)
    }
    if (-not [string]::IsNullOrWhiteSpace($InputFile)) {
        $arguments += @("--input", $InputFile)
    }

    return Invoke-GitHubCli -RootDir $RootDir -Arguments $arguments -AllowFailure:$AllowFailure
}

function Get-GitHubRepositoryInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir
    )

    $result = Invoke-GitHubCli -RootDir $RootDir -Arguments @("repo", "view", "--json", "nameWithOwner,defaultBranchRef,url")
    $repo = Convert-GitHubJson -JsonText $result.Output -Label "gh repo view"
    $defaultBranch = ""
    if ($null -ne $repo.defaultBranchRef) {
        $defaultBranch = [string]$repo.defaultBranchRef.name
    }

    return [pscustomobject]@{
        NameWithOwner = [string]$repo.nameWithOwner
        DefaultBranch = $defaultBranch
        Url = [string]$repo.url
    }
}

function Get-GitHubRepositoryRulesetSummaries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir
    )

    $result = Invoke-GitHubApi -RootDir $RootDir -Endpoint "repos/{owner}/{repo}/rulesets"
    if ([string]::IsNullOrWhiteSpace($result.Output)) {
        return [object[]]@()
    }

    $parsed = Convert-GitHubJson -JsonText $result.Output -Label "repository rulesets"
    return ConvertTo-HarnessObjectArray -Value $parsed
}

function Get-GitHubRepositoryRulesetDetails {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir
    )

    $details = New-Object System.Collections.Generic.List[object]
    foreach ($summary in (ConvertTo-HarnessObjectArray -Value (Get-GitHubRepositoryRulesetSummaries -RootDir $RootDir))) {
        $id = [string]$summary.id
        if ([string]::IsNullOrWhiteSpace($id)) {
            $details.Add($summary) | Out-Null
            continue
        }

        $result = Invoke-GitHubApi -RootDir $RootDir -Endpoint ("repos/{owner}/{repo}/rulesets/" + $id)
        $details.Add((Convert-GitHubJson -JsonText $result.Output -Label "repository ruleset $id")) | Out-Null
    }

    return $details.ToArray()
}

function Test-GitHubRuleRefPatternMatches {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Pattern,
        [Parameter(Mandatory = $true)]
        [string]$BranchName,
        [string]$DefaultBranch
    )

    if ($Pattern -eq "~ALL") {
        return $true
    }
    if ($Pattern -eq "~DEFAULT_BRANCH") {
        return (-not [string]::IsNullOrWhiteSpace($DefaultBranch) -and $DefaultBranch -eq $BranchName)
    }
    if ($Pattern -eq $BranchName -or $Pattern -eq ("refs/heads/" + $BranchName)) {
        return $true
    }

    $escaped = [System.Text.RegularExpressions.Regex]::Escape($Pattern)
    $escaped = $escaped -replace "\\\*", ".*"
    $candidateRefs = @($BranchName, ("refs/heads/" + $BranchName))
    foreach ($candidate in $candidateRefs) {
        if ($candidate -match ("^" + $escaped + "$")) {
            return $true
        }
    }

    return $false
}

function Test-GitHubRulesetTargetsBranch {
    param(
        [Parameter(Mandatory = $true)]
        $Ruleset,
        [Parameter(Mandatory = $true)]
        [string]$BranchName,
        [string]$DefaultBranch
    )

    if ([string]$Ruleset.target -ne "branch") {
        return $false
    }
    if ([string]$Ruleset.enforcement -ne "active") {
        return $false
    }

    $refName = $Ruleset.conditions.ref_name
    if ($null -eq $refName) {
        return $true
    }

    $included = $false
    foreach ($includePattern in @($refName.include)) {
        if (Test-GitHubRuleRefPatternMatches -Pattern ([string]$includePattern) -BranchName $BranchName -DefaultBranch $DefaultBranch) {
            $included = $true
            break
        }
    }

    if (-not $included) {
        return $false
    }

    foreach ($excludePattern in @($refName.exclude)) {
        if (Test-GitHubRuleRefPatternMatches -Pattern ([string]$excludePattern) -BranchName $BranchName -DefaultBranch $DefaultBranch) {
            return $false
        }
    }

    return $true
}

function Get-GitHubRulesByType {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rulesets,
        [Parameter(Mandatory = $true)]
        [string]$Type
    )

    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($ruleset in @($Rulesets)) {
        foreach ($rule in @($ruleset.rules)) {
            if ([string]$rule.type -eq $Type) {
                $matches.Add($rule) | Out-Null
            }
        }
    }

    return $matches.ToArray()
}

function Test-GitHubRulesHaveRequiredCheck {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rules,
        [Parameter(Mandatory = $true)]
        [string]$RequiredCheckName
    )

    foreach ($rule in @($Rules)) {
        foreach ($check in @($rule.parameters.required_status_checks)) {
            if ([string]$check.context -eq $RequiredCheckName) {
                return $true
            }
        }
    }

    return $false
}

function Test-GitHubRulesHaveStrictStatusPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rules
    )

    foreach ($rule in @($Rules)) {
        if ($rule.parameters.strict_required_status_checks_policy -eq $true) {
            return $true
        }
    }

    return $false
}

function Get-GitHubPolicyAudit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir,
        [Parameter(Mandatory = $true)]
        [string]$MainBranch,
        [string]$RequiredCheckName = $script:HarnessGitHubRequiredCheckName,
        [int]$RequiredApprovals = 1,
        [switch]$RequireCodeOwnerReview,
        [switch]$RequireMergeQueue,
        # Deletion and force-push protection only (e.g. dev, which is updated by
        # locally authorized merges and therefore cannot require PRs or checks).
        [switch]$ProtectionOnly
    )

    $repo = Get-GitHubRepositoryInfo -RootDir $RootDir
    $rulesets = ConvertTo-HarnessObjectArray -Value (Get-GitHubRepositoryRulesetDetails -RootDir $RootDir)
    $matchingRulesets = ConvertTo-HarnessObjectArray -Value ($rulesets | Where-Object {
            Test-GitHubRulesetTargetsBranch -Ruleset $_ -BranchName $MainBranch -DefaultBranch $repo.DefaultBranch
        })

    $issues = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($repo.NameWithOwner)) {
        $issues.Add("GitHub repository could not be resolved from the current directory") | Out-Null
    }
    if (-not $ProtectionOnly -and -not [string]::IsNullOrWhiteSpace($repo.DefaultBranch) -and $repo.DefaultBranch -ne $MainBranch) {
        $warnings.Add("GitHub default branch '$($repo.DefaultBranch)' differs from harness main branch '$MainBranch'") | Out-Null
    }
    if ($matchingRulesets.Count -eq 0) {
        $issues.Add("no active branch ruleset targets '$MainBranch'") | Out-Null
    }

    if ((Get-GitHubRulesByType -Rulesets $matchingRulesets -Type "deletion").Count -eq 0) {
        $issues.Add("missing deletion protection for '$MainBranch'") | Out-Null
    }
    if ((Get-GitHubRulesByType -Rulesets $matchingRulesets -Type "non_fast_forward").Count -eq 0) {
        $issues.Add("missing non-fast-forward protection for '$MainBranch'") | Out-Null
    }

    $pullRequestRules = ConvertTo-HarnessObjectArray -Value (Get-GitHubRulesByType -Rulesets $matchingRulesets -Type "pull_request")
    if ($ProtectionOnly) {
        # PR, status check, merge queue and workflow requirements do not apply.
    } elseif ($pullRequestRules.Count -eq 0) {
        $issues.Add("missing pull request requirement for '$MainBranch'") | Out-Null
    } else {
        $approvalOk = $false
        $staleReviewOk = $false
        $threadResolutionOk = $false
        $codeOwnerOk = -not $RequireCodeOwnerReview
        foreach ($rule in $pullRequestRules) {
            $count = 0
            if ($null -ne $rule.parameters.required_approving_review_count) {
                $count = [int]$rule.parameters.required_approving_review_count
            }
            if ($count -ge $RequiredApprovals) {
                $approvalOk = $true
            }
            if ($rule.parameters.dismiss_stale_reviews_on_push -eq $true) {
                $staleReviewOk = $true
            }
            if ($rule.parameters.required_review_thread_resolution -eq $true) {
                $threadResolutionOk = $true
            }
            if ($RequireCodeOwnerReview -and $rule.parameters.require_code_owner_review -eq $true) {
                $codeOwnerOk = $true
            }
        }

        if (-not $approvalOk) {
            $issues.Add("pull request rule requires fewer than $RequiredApprovals approving review(s)") | Out-Null
        }
        if (-not $staleReviewOk) {
            $warnings.Add("pull request rule does not dismiss stale reviews on push") | Out-Null
        }
        if (-not $threadResolutionOk) {
            $warnings.Add("pull request rule does not require review thread resolution") | Out-Null
        }
        if (-not $codeOwnerOk) {
            $issues.Add("pull request rule does not require CODEOWNERS review") | Out-Null
        }
    }

    $statusRules = ConvertTo-HarnessObjectArray -Value (Get-GitHubRulesByType -Rulesets $matchingRulesets -Type "required_status_checks")
    if ($ProtectionOnly) {
        # not required for a protection-only branch
    } elseif ($statusRules.Count -eq 0) {
        $issues.Add("missing required status checks for '$MainBranch'") | Out-Null
    } else {
        if (-not (Test-GitHubRulesHaveRequiredCheck -Rules $statusRules -RequiredCheckName $RequiredCheckName)) {
            $issues.Add("required status checks do not include '$RequiredCheckName'") | Out-Null
        }
        if (-not (Test-GitHubRulesHaveStrictStatusPolicy -Rules $statusRules)) {
            $issues.Add("required status checks are not configured with strict latest-code policy") | Out-Null
        }
    }

    if (-not $ProtectionOnly -and $RequireMergeQueue -and (Get-GitHubRulesByType -Rulesets $matchingRulesets -Type "merge_queue").Count -eq 0) {
        $issues.Add("merge queue is required but no merge_queue rule targets '$MainBranch'") | Out-Null
    }

    $workflowPath = Resolve-ProjectPath -RootDir $RootDir -ProjectPath ".github/workflows/harness-ci.yml" -Label "github actions workflow"
    if (-not $ProtectionOnly -and -not (Test-Path -LiteralPath $workflowPath)) {
        $warnings.Add("local .github/workflows/harness-ci.yml is missing; install it before relying on '$RequiredCheckName'") | Out-Null
    }

    return [pscustomobject]@{
        Status = $(if ($issues.Count -eq 0) { "pass" } else { "fail" })
        Repository = $repo
        MainBranch = $MainBranch
        RequiredCheckName = $RequiredCheckName
        RequiredApprovals = $RequiredApprovals
        RequireCodeOwnerReview = [bool]$RequireCodeOwnerReview
        RequireMergeQueue = [bool]$RequireMergeQueue
        ProtectionOnly = [bool]$ProtectionOnly
        Rulesets = $rulesets
        MatchingRulesets = $matchingRulesets
        Issues = $issues.ToArray()
        Warnings = $warnings.ToArray()
    }
}

function New-HarnessGitHubRulesetPayload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MainBranch,
        [string]$RulesetName = $script:HarnessGitHubRulesetName,
        [string]$RequiredCheckName = $script:HarnessGitHubRequiredCheckName,
        [int]$RequiredApprovals = 1,
        [switch]$RequireCodeOwnerReview,
        [switch]$RequireMergeQueue,
        [switch]$ProtectionOnly
    )

    $rules = New-Object System.Collections.Generic.List[object]
    $rules.Add([ordered]@{ type = "deletion" }) | Out-Null
    $rules.Add([ordered]@{ type = "non_fast_forward" }) | Out-Null
    if (-not $ProtectionOnly) {
        $rules.Add([ordered]@{
                type = "pull_request"
                parameters = [ordered]@{
                    allowed_merge_methods = @("merge", "squash", "rebase")
                    dismiss_stale_reviews_on_push = $true
                    require_code_owner_review = [bool]$RequireCodeOwnerReview
                    require_last_push_approval = $false
                    required_approving_review_count = $RequiredApprovals
                    required_review_thread_resolution = $true
                }
            }) | Out-Null
        $rules.Add([ordered]@{
                type = "required_status_checks"
                parameters = [ordered]@{
                    do_not_enforce_on_create = $false
                    strict_required_status_checks_policy = $true
                    required_status_checks = @(
                        [ordered]@{
                            context = $RequiredCheckName
                        }
                    )
                }
            }) | Out-Null

        if ($RequireMergeQueue) {
            $rules.Add([ordered]@{
                    type = "merge_queue"
                    parameters = [ordered]@{
                        check_response_timeout_minutes = 60
                        grouping_strategy = "ALLGREEN"
                        max_entries_to_build = 5
                        max_entries_to_merge = 1
                        merge_method = "MERGE"
                        min_entries_to_merge = 1
                        min_entries_to_merge_wait_minutes = 0
                    }
                }) | Out-Null
        }
    }

    return [ordered]@{
        name = $RulesetName
        target = "branch"
        enforcement = "active"
        bypass_actors = @()
        conditions = [ordered]@{
            ref_name = [ordered]@{
                include = @("refs/heads/" + $MainBranch)
                exclude = @()
            }
        }
        rules = $rules.ToArray()
    }
}

function Format-GitHubPolicyList {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Items,
        [string]$EmptyText = "none"
    )

    if ($Items.Count -eq 0) {
        return "- $EmptyText"
    }

    return (($Items | ForEach-Object { "- " + [string]$_ }) -join [Environment]::NewLine)
}
