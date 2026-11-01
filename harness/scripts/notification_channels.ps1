# Run-stop notifications to Telegram and a Discord webhook. Settings that a GUI may
# edit live in local state; secrets stay in environment variables and are never
# written to settings, logs or output.
$script:HarnessNotificationEvents = @('stop','budget','completion')
$script:HarnessNotificationChannels = @('telegram','discord')

function Get-HarnessNotificationSettingsPath([string]$RootDir) {
    return Resolve-HarnessEnginePath $RootDir 'harness/state/notifications/settings.json' 'notification settings'
}

function New-HarnessDefaultNotificationSettings {
    return [pscustomobject]@{
        version = 1
        channels = [pscustomobject]@{ telegram = $true; discord = $true }
        events = [pscustomobject]@{ stop = $true; budget = $true; completion = $false }
        # Quiet hours deliver silently now; reminders (interval, count, wait limit) are
        # read by the waiting run that sends follow-ups.
        quiet_hours = [pscustomobject]@{ enabled = $false; start = '23:00'; end = '08:00' }
        reminder = [pscustomobject]@{ interval_minutes = 120; max_count = 5; wait_limit_hours = 12 }
    }
}

function Assert-HarnessNotificationSettings($Settings) {
    if ($null -eq $Settings -or $Settings.version -ne 1) { throw 'notification settings must have version 1' }
    foreach ($field in $Settings.PSObject.Properties.Name) { if ($field -cnotin @('version','channels','events','quiet_hours','reminder')) { throw "unknown notification setting: $field" } }
    foreach ($name in $script:HarnessNotificationChannels) { if ($Settings.channels.$name -isnot [bool]) { throw "channels.$name must be true or false" } }
    foreach ($name in $script:HarnessNotificationEvents) { if ($Settings.events.$name -isnot [bool]) { throw "events.$name must be true or false" } }
    if ($Settings.quiet_hours.enabled -isnot [bool]) { throw 'quiet_hours.enabled must be true or false' }
    foreach ($name in @('start','end')) { if ([string]$Settings.quiet_hours.$name -cnotmatch '^(?:[01]\d|2[0-3]):[0-5]\d$') { throw "quiet_hours.$name must be HH:mm" } }
    $limits = @{ interval_minutes = @(10, 1440); max_count = @(0, 50); wait_limit_hours = @(1, 72) }
    foreach ($name in $limits.Keys) {
        $value = $Settings.reminder.$name
        if (-not (Test-HarnessUsageInteger $value) -or $value -lt $limits[$name][0] -or $value -gt $limits[$name][1]) { throw "reminder.$name must be $($limits[$name][0])..$($limits[$name][1])" }
    }
}

function Get-HarnessNotificationSettings([string]$RootDir) {
    $path = Get-HarnessNotificationSettingsPath $RootDir
    if (-not (Test-Path -LiteralPath $path)) { return New-HarnessDefaultNotificationSettings }
    try { $settings = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { throw 'invalid notification settings JSON' }
    Assert-HarnessNotificationSettings $settings
    return $settings
}

function Save-HarnessNotificationSettings([string]$RootDir, $Settings) {
    Assert-HarnessNotificationSettings $Settings
    Write-Utf8File (Get-HarnessNotificationSettingsPath $RootDir) ($Settings | ConvertTo-Json -Depth 5)
}

function Test-HarnessQuietTime($Settings, [DateTime]$Now) {
    if (-not $Settings.quiet_hours.enabled) { return $false }
    $minutes = $Now.Hour * 60 + $Now.Minute
    $start = [int]$Settings.quiet_hours.start.Substring(0, 2) * 60 + [int]$Settings.quiet_hours.start.Substring(3, 2)
    $end = [int]$Settings.quiet_hours.end.Substring(0, 2) * 60 + [int]$Settings.quiet_hours.end.Substring(3, 2)
    if ($start -eq $end) { return $false }
    if ($start -lt $end) { return ($minutes -ge $start -and $minutes -lt $end) }
    return ($minutes -ge $start -or $minutes -lt $end)
}

function Get-HarnessNotificationTargets($Settings) {
    # A channel is used only when it is enabled and its secrets are present.
    $targets = New-Object 'System.Collections.Generic.List[string]'
    if ($Settings.channels.telegram -and $env:HARNESS_TELEGRAM_BOT_TOKEN -and $env:HARNESS_TELEGRAM_CHAT_ID) { $targets.Add('telegram') | Out-Null }
    if ($Settings.channels.discord -and $env:HARNESS_DISCORD_WEBHOOK_URL) { $targets.Add('discord') | Out-Null }
    return $targets.ToArray()
}

function Protect-HarnessNotificationText([AllowEmptyString()][string]$Text) {
    $value = Protect-HarnessSecretText $Text
    foreach ($secret in @($env:HARNESS_TELEGRAM_BOT_TOKEN, $env:HARNESS_DISCORD_WEBHOOK_URL)) {
        if (-not [string]::IsNullOrEmpty($secret) -and $secret.Length -ge 8) { $value = $value.Replace($secret, '[REDACTED]') }
    }
    return $value
}

function Send-HarnessNotificationToChannel([string]$Channel, [string]$Text, [bool]$Silent) {
    if ($Channel -eq 'discord' -and [string]$env:HARNESS_DISCORD_WEBHOOK_URL -cnotmatch '^https://(?:discord|discordapp)\.com/api/webhooks/') { throw 'HARNESS_DISCORD_WEBHOOK_URL is not a Discord webhook URL' }
    $capture = $env:HARNESS_NOTIFY_CAPTURE_FILE
    if (-not [string]::IsNullOrWhiteSpace($capture)) {
        # Test transport: record the payload instead of sending it.
        Append-Utf8File $capture ((@{ channel = $Channel; silent = $Silent; text = $Text } | ConvertTo-Json -Compress) + "`n")
        return
    }
    if ($Channel -eq 'telegram') {
        $body = @{ chat_id = $env:HARNESS_TELEGRAM_CHAT_ID; text = $Text; disable_notification = $Silent }
        Invoke-RestMethod -Method Post -Uri ('https://api.telegram.org/bot' + $env:HARNESS_TELEGRAM_BOT_TOKEN + '/sendMessage') -Body $body -TimeoutSec 15 | Out-Null
        return
    }
    $url = [string]$env:HARNESS_DISCORD_WEBHOOK_URL
    $payload = @{ content = $Text }
    # 4096 = SUPPRESS_NOTIFICATIONS: delivered without a push during quiet hours.
    if ($Silent) { $payload.flags = 4096 }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress))
    Invoke-RestMethod -Method Post -Uri $url -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 15 | Out-Null
}

function Send-HarnessNotification([string]$RootDir, [string]$EventName, [string]$Text, $Now = $null) {
    if ($EventName -cnotin $script:HarnessNotificationEvents) { throw "unknown notification event: $EventName" }
    $results = New-Object 'System.Collections.Generic.List[object]'
    if (@('1','true','yes','on') -contains ([string]$env:HARNESS_NOTIFY_DISABLED).Trim().ToLowerInvariant()) { return $results.ToArray() }
    $settings = Get-HarnessNotificationSettings $RootDir
    if (-not $settings.events.$EventName) { return $results.ToArray() }
    if ($null -eq $Now) { $Now = Get-Date }
    $silent = Test-HarnessQuietTime $settings ([DateTime]$Now)
    $message = Protect-HarnessNotificationText $Text
    if ($message.Length -gt 1900) { $message = $message.Substring(0, 1900) + "`n[truncated]" }
    foreach ($channel in @(Get-HarnessNotificationTargets $settings)) {
        $status = 'sent'; $detail = ''
        try { Send-HarnessNotificationToChannel $channel $message $silent }
        catch { $status = 'failed'; $detail = Protect-HarnessNotificationText $_.Exception.Message }
        $results.Add([pscustomobject]@{ channel = $channel; status = $status; silent = $silent; detail = $detail }) | Out-Null
        $logPath = Get-HarnessConfiguredPath -RootDir $RootDir -Name 'notification_log' -FallbackRelativePath 'harness/reports/notifications_log.md'
        if (-not (Test-Path -LiteralPath $logPath)) { Write-Utf8File $logPath "# Notification Log`n`n## Entries`n" }
        Append-Utf8File $logPath ("- time: {0}`n  - provider: {1}`n  - event: {2}`n  - status: {3}`n  - silent: {4}`n  - detail: {5}`n" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $channel, $EventName, $status, ([string]$silent).ToLowerInvariant(), $(if ($detail) { $detail } else { 'none' }))
    }
    return $results.ToArray()
}

# Notifications are fixed Korean templates filled locally (no AI call, no tokens). Known engine
# reasons map to a short Korean phrase; anything else keeps only a short excerpt of the original.
function ConvertTo-HarnessKoreanReason([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $rules = @(
        @('no unique execution evidence', '완료 기록 거부: 검증 증거가 하나로 정해지지 않음'),
        @('permission problem|denied tool use', '권한 문제: 필요한 도구 사용이 거부됨'),
        @('usage limit', 'AI 사용량 한도 도달'),
        @('budget', '실행 한도 도달'),
        @('repeated', '같은 오류 반복'),
        @('unresolved worker|worker_unresolved', '종료가 확인되지 않은 worker가 있음'),
        @('requires resume', '이전 실패 작업이 있어 재개 필요'),
        @('provider reported execution failure', 'AI 실행 결과가 실패로 보고됨'),
        @('preflight', '사전 점검 실패'),
        @('timed out|timeout', '시간 초과'),
        @('environment|docker|InvalidPathException', '환경 문제'),
        @('validation|tests? failed', '검증 실패')
    )
    $korean = $null
    foreach ($rule in $rules) { if ($Text -match ('(?i)' + $rule[0])) { $korean = $rule[1]; break } }
    if ($null -eq $korean) {
        $plain = ($Text -replace '\s+', ' ').Trim()
        if ($plain.Length -gt 100) { $plain = $plain.Substring(0, 100) + '...' }
        return "분류되지 않은 오류: $plain"
    }
    if ($Text -match '\((\d+) of (\d+)') { $korean += " ($($Matches[1])/$($Matches[2]))" }
    return $korean
}

function Format-HarnessAssignmentLabel([string]$AssignmentId) {
    # plan__01__task-name -> "01 task-name"
    $parts = @($AssignmentId -split '__' | Where-Object { $_ })
    if ($parts.Count -ge 3) { return ($parts[-2] + ' ' + $parts[-1]) }
    return $AssignmentId
}

function Format-HarnessStopNotification([string]$Project, [string]$StopKind, [string]$AssignmentId, [string]$Reason, [string]$PlanFile) {
    $title = switch ($StopKind) {
        'budget' { '[Harness] 비용 한도 도달' }
        'repeated_failure' { '[Harness] 같은 오류 반복으로 중단' }
        'completion' { '[Harness] 계획 완료' }
        'error' { '[Harness] 실행 오류로 중단' }
        default { '[Harness] 사용자 확인 필요' }
    }
    $next = switch ($StopKind) {
        'budget' { '사용량 확인: harness.ps1 usage' }
        'repeated_failure' { "실패 메모(harness/state/failures/$AssignmentId.md) 확인 후 harness.ps1 attempts -Grant 1" }
        'completion' { 'main 반영 승인 대기' }
        'error' { "로그(reports/agent_runs) 확인 후 harness.ps1 resume -PlanFile $PlanFile -Execute" }
        default { "원인 해결 후 harness.ps1 resume -PlanFile $PlanFile -Execute" }
    }
    $lines = @($title, "프로젝트: $Project")
    if ($AssignmentId -and $AssignmentId -ne 'none') { $lines += "작업: $(Format-HarnessAssignmentLabel $AssignmentId)" }
    if ($Reason) { $lines += "원인: $(ConvertTo-HarnessKoreanReason $Reason)" }
    $lines += "다음: $next"
    return ($lines -join "`n")
}
