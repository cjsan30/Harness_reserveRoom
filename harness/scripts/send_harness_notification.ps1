param(
    [string]$StatusFile = "",
    [string]$Message = "",
    [ValidateSet("", "telegram", "none")]
    [string]$Provider = "",
    [ValidateSet("", "attention", "action_required", "failure", "all")]
    [string]$Level = "",
    [switch]$Force,
    [switch]$DryRun,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "harness_common.ps1")

$rootDir = Get-HarnessRoot -ScriptDirectory $PSScriptRoot

function Get-EnvValue {
    param([string]$Name)
    return [Environment]::GetEnvironmentVariable($Name)
}

function Test-Truthy {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return @("1", "true", "yes", "on") -contains $Value.Trim().ToLowerInvariant()
}

function Get-TextHash {
    param([string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hashBytes = $sha.ComputeHash($bytes)
        return (($hashBytes | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $sha.Dispose()
    }
}

function Resolve-StatusPath {
    param([string]$RequestedStatusFile)

    if (-not [string]::IsNullOrWhiteSpace($RequestedStatusFile)) {
        return Resolve-ProjectPath -RootDir $rootDir -ProjectPath $RequestedStatusFile -Label "notification.status_file"
    }

    return Get-HarnessConfiguredPath -RootDir $rootDir -Name "status_json" -FallbackRelativePath "harness/reports/status.json"
}

function Get-NotificationDecision {
    param(
        [AllowNull()]
        $Status,
        [string]$NotifyLevel,
        [switch]$ForceNotify
    )

    if ($ForceNotify) {
        return [pscustomobject]@{
            ShouldNotify = $true
            Reason = "force"
        }
    }

    if ($null -eq $Status) {
        return [pscustomobject]@{
            ShouldNotify = (-not [string]::IsNullOrWhiteSpace($Message))
            Reason = "custom_message"
        }
    }

    $statusName = [string]$Status.status
    $phase = [string]$Status.phase
    $failureType = if ($null -ne $Status.failure) { [string]$Status.failure.type } else { "none" }
    $statusUserAction = $false
    $failureUserAction = $false
    if ($null -ne $Status.user_action_required) {
        $statusUserAction = [bool]$Status.user_action_required
    }
    if ($null -ne $Status.failure -and $null -ne $Status.failure.user_action_required) {
        $failureUserAction = [bool]$Status.failure.user_action_required
    }

    $isFailure = ($statusName -match "(?i)(fail|failed|blocked)")
    $isAttention = $statusUserAction -or $failureUserAction -or
        ($statusName -in @(
            "needs_user_input",
            "needs_baseline_commit",
            "preflight_failed",
            "seed_failed",
            "cycle_failed",
            "deferred_questions"
        )) -or
        ($phase -in @("intake_review", "baseline")) -or
        ($failureType -in @("secret", "requirements", "environment"))

    switch ($NotifyLevel) {
        "all" {
            return [pscustomobject]@{ ShouldNotify = $true; Reason = "all" }
        }
        "failure" {
            return [pscustomobject]@{ ShouldNotify = $isFailure; Reason = "failure" }
        }
        "action_required" {
            return [pscustomobject]@{ ShouldNotify = ($statusUserAction -or $failureUserAction); Reason = "action_required" }
        }
        default {
            return [pscustomobject]@{ ShouldNotify = $isAttention; Reason = "attention" }
        }
    }
}

function Format-HarnessNotificationMessage {
    param(
        [AllowNull()]
        $Status,
        [string]$CustomMessage = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($CustomMessage)) {
        return $CustomMessage.Trim()
    }

    if ($null -eq $Status) {
        return "Harness notification"
    }

    $failureType = if ($null -ne $Status.failure) { [string]$Status.failure.type } else { "none" }
    $failureAction = if ($null -ne $Status.failure) { [string]$Status.failure.next_action } else { "none" }
    $nextActions = if ($null -ne $Status.next_actions -and @($Status.next_actions).Count -gt 0) {
        (@($Status.next_actions) | ForEach-Object { "- " + [string]$_ }) -join [Environment]::NewLine
    } else {
        "- none"
    }
    $blocking = if ($null -ne $Status.blocking -and @($Status.blocking).Count -gt 0) {
        (@($Status.blocking) | ForEach-Object { "- " + [string]$_ }) -join [Environment]::NewLine
    } else {
        "- none"
    }

    $messageText = @"
[Harness] Attention Required

status: $($Status.status)
phase: $($Status.phase)
user_action_required: $($Status.user_action_required)
failure: $failureType

blocking:
$blocking

next_actions:
$nextActions

failure_next_action: $failureAction
next_command: $($Status.next_command)
root: $rootDir
"@

    if ($messageText.Length -gt 3800) {
        return $messageText.Substring(0, 3800) + [Environment]::NewLine + "[truncated]"
    }

    return $messageText
}

function Append-NotificationLog {
    param(
        [string]$Status,
        [string]$Reason,
        [string]$Signature,
        [string]$Detail = ""
    )

    $logPath = Get-HarnessConfiguredPath -RootDir $rootDir -Name "notification_log" -FallbackRelativePath "harness/reports/notifications_log.md"
    if (-not (Test-Path -LiteralPath $logPath)) {
        Write-Utf8File -Path $logPath -Content "# Notification Log`n`n## Entries`n"
    }

    $entry = @"
- time: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
  - provider: telegram
  - status: $Status
  - reason: $Reason
  - signature: $Signature
  - detail: $Detail
"@
    Append-Utf8File -Path $logPath -Content $entry
}

if (Test-Truthy -Value (Get-EnvValue -Name "HARNESS_NOTIFY_DISABLED")) {
    if (-not $Quiet) {
        Write-Output "notification skipped: disabled"
    }
    exit 0
}

$resolvedProvider = $Provider
if ([string]::IsNullOrWhiteSpace($resolvedProvider)) {
    $resolvedProvider = Get-EnvValue -Name "HARNESS_NOTIFY_PROVIDER"
}
if ([string]::IsNullOrWhiteSpace($resolvedProvider)) {
    if (-not [string]::IsNullOrWhiteSpace((Get-EnvValue -Name "HARNESS_TELEGRAM_BOT_TOKEN")) -and
        -not [string]::IsNullOrWhiteSpace((Get-EnvValue -Name "HARNESS_TELEGRAM_CHAT_ID"))) {
        $resolvedProvider = "telegram"
    }
}
if ([string]::IsNullOrWhiteSpace($resolvedProvider)) {
    if (-not $Quiet) {
        Write-Output "notification skipped: provider not configured"
    }
    exit 0
}
if ($resolvedProvider -eq "none") {
    if (-not $Quiet) {
        Write-Output "notification skipped: provider none"
    }
    exit 0
}
if ($resolvedProvider -ne "telegram") {
    throw "unsupported notification provider: $resolvedProvider"
}

$resolvedLevel = $Level
if ([string]::IsNullOrWhiteSpace($resolvedLevel)) {
    $resolvedLevel = Get-EnvValue -Name "HARNESS_NOTIFY_LEVEL"
}
if ([string]::IsNullOrWhiteSpace($resolvedLevel)) {
    $resolvedLevel = "attention"
}

$statusObject = $null
$statusPath = ""
try {
    $statusPath = Resolve-StatusPath -RequestedStatusFile $StatusFile
    if (Test-Path -LiteralPath $statusPath) {
        $statusObject = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json
    }
} catch {
    if ([string]::IsNullOrWhiteSpace($Message)) {
        if (-not $Quiet) {
            Write-Output ("notification skipped: cannot read status file: " + $_.Exception.Message)
        }
        exit 0
    }
}

$decision = Get-NotificationDecision -Status $statusObject -NotifyLevel $resolvedLevel -ForceNotify:$Force
if (-not $decision.ShouldNotify) {
    if (-not $Quiet) {
        Write-Output "notification skipped: no matching attention condition"
    }
    exit 0
}

$messageText = Format-HarnessNotificationMessage -Status $statusObject -CustomMessage $Message
$signatureSource = @(
    $resolvedProvider,
    $resolvedLevel,
    $messageText,
    $(if ($null -eq $statusObject) { "" } else { [string]$statusObject.status }),
    $(if ($null -eq $statusObject) { "" } else { [string]$statusObject.phase }),
    $(if ($null -eq $statusObject -or $null -eq $statusObject.failure) { "" } else { [string]$statusObject.failure.type }),
    $(if ($null -eq $statusObject -or $null -eq $statusObject.failure) { "" } else { [string]$statusObject.failure.message })
) -join "|"
$signature = Get-TextHash -Text $signatureSource

$stateDir = Get-HarnessConfiguredPath -RootDir $rootDir -Name "notification_state" -FallbackRelativePath "harness/state/notifications"
Ensure-HarnessDirectory -Path $stateDir
$statePath = Join-Path $stateDir "last_notification.json"
if (-not $Force -and (Test-Path -LiteralPath $statePath)) {
    try {
        $lastState = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
        if ([string]$lastState.signature -eq $signature) {
            if (-not $Quiet) {
                Write-Output "notification skipped: duplicate"
            }
            exit 0
        }
    } catch {
        # Ignore malformed state and continue with a fresh notification.
    }
}

if ($DryRun) {
    Write-Output "notification dry-run: telegram"
    Write-Output $messageText
    Append-NotificationLog -Status "dry_run" -Reason $decision.Reason -Signature $signature -Detail "message not sent"
    exit 0
} else {
    $botToken = Get-EnvValue -Name "HARNESS_TELEGRAM_BOT_TOKEN"
    $chatId = Get-EnvValue -Name "HARNESS_TELEGRAM_CHAT_ID"
    if ([string]::IsNullOrWhiteSpace($botToken) -or [string]::IsNullOrWhiteSpace($chatId)) {
        if (-not $Quiet) {
            Write-Output "notification skipped: HARNESS_TELEGRAM_BOT_TOKEN or HARNESS_TELEGRAM_CHAT_ID is missing"
        }
        exit 0
    }

    $body = @{
        chat_id = $chatId
        text = $messageText
    }
    Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot" + $botToken + "/sendMessage") -Body $body | Out-Null
    Append-NotificationLog -Status "sent" -Reason $decision.Reason -Signature $signature -Detail "telegram sendMessage"
    if (-not $Quiet) {
        Write-Output "notification sent: telegram"
    }
}

$stateObject = [pscustomobject]@{
    signature = $signature
    provider = $resolvedProvider
    level = $resolvedLevel
    status = $(if ($null -eq $statusObject) { "custom" } else { [string]$statusObject.status })
    phase = $(if ($null -eq $statusObject) { "custom" } else { [string]$statusObject.phase })
    notified_at = (Get-Date).ToString("o")
    status_file = $(if ([string]::IsNullOrWhiteSpace($statusPath)) { "none" } else { Get-RelativeProjectPath -RootDir $rootDir -AbsolutePath $statusPath })
}
Write-Utf8File -Path $statePath -Content ($stateObject | ConvertTo-Json -Depth 10)
