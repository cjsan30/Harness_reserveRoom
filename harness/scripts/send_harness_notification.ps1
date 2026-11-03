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
        return "[Harness] 알림"
    }

    $statusText = switch ([string]$Status.status) {
        'seed_failed' { '실행 실패' }
        'cycle_failed' { '검증 사이클 실패' }
        'preflight_failed' { '사전 점검 실패' }
        'needs_user_input' { '사용자 입력 필요' }
        'needs_profile' { '대상 프로필 없음' }
        'needs_preflight' { '사전 점검 필요' }
        'needs_baseline_commit' { '기준 커밋 필요' }
        'needs_intake' { '요구사항 정리 필요' }
        'seed_live_passed' { '실행 통과' }
        default { "확인 필요 ($([string]$Status.status))" }
    }
    $reasonSource = ''
    if ($null -ne $Status.failure -and -not [string]::IsNullOrWhiteSpace([string]$Status.failure.message)) { $reasonSource = [string]$Status.failure.message }
    elseif ($null -ne $Status.blocking -and @($Status.blocking).Count -gt 0) { $reasonSource = [string]@($Status.blocking)[0] }
    $lines = @("[Harness] $statusText", "프로젝트: $(Split-Path -Leaf $rootDir)")
    if ($reasonSource) { $lines += "원인: $(ConvertTo-HarnessKoreanReason $reasonSource)" }
    if ($Status.user_action_required -eq $true) { $lines += '사용자 조치: 필요' }
    $lines += '다음: harness.ps1 status 또는 현황판에서 확인'
    $messageText = $lines -join [Environment]::NewLine

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

# Status snapshots run often, so routine outcomes (no attention needed, duplicate) only
# replace the last decision; outcomes an operator must act on are also logged.
function Save-StatusNotificationDecision {
    param([string]$Decision, [string]$Reason, [switch]$Log)
    try {
        $decisionDir = Get-HarnessConfiguredPath -RootDir $rootDir -Name "notification_state" -FallbackRelativePath "harness/state/notifications"
        Ensure-HarnessDirectory -Path $decisionDir
        $record = [pscustomobject]@{ decided_at = (Get-Date).ToString("o"); decision = $Decision; reason = (Protect-HarnessNotificationText $Reason) }
        Write-Utf8File -Path (Join-Path $decisionDir "last_status_decision.json") -Content ($record | ConvertTo-Json -Depth 3)
        if ($Log) { Append-NotificationLog -Status $Decision -Reason "status" -Signature "none" -Detail (Protect-HarnessNotificationText $Reason) }
    } catch {
        # Recording the decision never blocks the status snapshot.
    }
    if (-not $Quiet) { Write-Output ("notification {0}: {1}" -f $Decision, $Reason) }
}

if (Test-Truthy -Value (Get-EnvValue -Name "HARNESS_NOTIFY_DISABLED")) {
    Save-StatusNotificationDecision -Decision "skipped" -Reason "HARNESS_NOTIFY_DISABLED is set; unset it to send notifications" -Log
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
    $missingReason = Get-HarnessMissingSecretReason "telegram"
    Save-StatusNotificationDecision -Decision "skipped" -Reason $(if ($missingReason) { "provider not configured: $missingReason" } else { "provider not configured" }) -Log
    exit 0
}
if ($resolvedProvider -eq "none") {
    Save-StatusNotificationDecision -Decision "skipped" -Reason "HARNESS_NOTIFY_PROVIDER is none"
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
        Save-StatusNotificationDecision -Decision "skipped" -Reason ("cannot read status file: " + $_.Exception.Message) -Log
        exit 0
    }
}

$decision = Get-NotificationDecision -Status $statusObject -NotifyLevel $resolvedLevel -ForceNotify:$Force
if (-not $decision.ShouldNotify) {
    Save-StatusNotificationDecision -Decision "skipped" -Reason "status needs no attention at level $resolvedLevel"
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
            Save-StatusNotificationDecision -Decision "skipped" -Reason ("same status was already sent at " + [string]$lastState.notified_at)
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
        Save-StatusNotificationDecision -Decision "skipped" -Reason (Get-HarnessMissingSecretReason "telegram") -Log
        exit 0
    }

    $body = @{
        chat_id = $chatId
        text = $messageText
    }
    try {
        Invoke-RestMethod -Method Post -Uri ("https://api.telegram.org/bot" + $botToken + "/sendMessage") -Body $body -TimeoutSec 15 | Out-Null
    } catch {
        Save-StatusNotificationDecision -Decision "failed" -Reason (Get-HarnessNotificationFailureDetail "telegram" $_) -Log
        exit 1
    }
    Append-NotificationLog -Status "sent" -Reason $decision.Reason -Signature $signature -Detail "telegram sendMessage"
    Save-StatusNotificationDecision -Decision "sent" -Reason "telegram sendMessage"
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
