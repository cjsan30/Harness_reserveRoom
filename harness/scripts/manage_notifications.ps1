param(
    # on/off values; omitted options keep the current setting.
    [ValidateSet('', 'on', 'off')][string]$Telegram = '',
    [ValidateSet('', 'on', 'off')][string]$Discord = '',
    [ValidateSet('', 'on', 'off')][string]$OnStop = '',
    [ValidateSet('', 'on', 'off')][string]$OnBudget = '',
    [ValidateSet('', 'on', 'off')][string]$OnCompletion = '',
    [ValidateSet('', 'on', 'off')][string]$QuietHours = '',
    [string]$QuietStart = '',
    [string]$QuietEnd = '',
    [int]$ReminderMinutes = 0,
    [int]$ReminderCount = -1,
    [int]$WaitHours = 0,
    # Sends a real message to every configured channel.
    [switch]$Test,
    # Explains why messages would not arrive: secrets, switches, a live bot/chat check
    # (no message is sent) and the latest log entries.
    [switch]$Check,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$root = Get-HarnessRoot $PSScriptRoot
$settings = Get-HarnessNotificationSettings $root
$changed = $false
function Set-Flag($Value, $Target, [string]$Name) { if ($Value) { $Target.$Name = ($Value -eq 'on'); $script:changed = $true } }
Set-Flag $Telegram $settings.channels 'telegram'
Set-Flag $Discord $settings.channels 'discord'
Set-Flag $OnStop $settings.events 'stop'
Set-Flag $OnBudget $settings.events 'budget'
Set-Flag $OnCompletion $settings.events 'completion'
Set-Flag $QuietHours $settings.quiet_hours 'enabled'
if ($QuietStart) { $settings.quiet_hours.start = $QuietStart; $changed = $true }
if ($QuietEnd) { $settings.quiet_hours.end = $QuietEnd; $changed = $true }
if ($ReminderMinutes -ne 0) { $settings.reminder.interval_minutes = $ReminderMinutes; $changed = $true }
if ($ReminderCount -ne -1) { $settings.reminder.max_count = $ReminderCount; $changed = $true }
if ($WaitHours -ne 0) { $settings.reminder.wait_limit_hours = $WaitHours; $changed = $true }
if ($changed) { Save-HarnessNotificationSettings $root $settings }

$targets = @(Get-HarnessNotificationTargets $settings)
$sent = @()
if ($Test) {
    $project = (Get-ProjectProfile -RootDir $root).project.name
    # A test is sent for every enabled channel regardless of the event switches.
    $copy = $settings | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $copy.events.stop = $true
    $path = Get-HarnessNotificationSettingsPath $root
    $original = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) } else { $null }
    try {
        Save-HarnessNotificationSettings $root $copy
        $sent = @(Send-HarnessNotification $root 'stop' "[Harness] 알림 테스트`nproject: $project")
    } finally {
        if ($null -eq $original) { Remove-Item -LiteralPath $path -Force } else { Write-Utf8File $path $original }
    }
}
$checkReport = $null
if ($Check) {
    $problems = New-Object 'System.Collections.Generic.List[string]'
    if (@('1','true','yes','on') -contains ([string]$env:HARNESS_NOTIFY_DISABLED).Trim().ToLowerInvariant()) { $problems.Add('HARNESS_NOTIFY_DISABLED is set: nothing is sent') | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($env:HARNESS_NOTIFY_CAPTURE_FILE)) { $problems.Add('HARNESS_NOTIFY_CAPTURE_FILE is set: messages go to a file, not the network') | Out-Null }
    if (-not ($settings.channels.telegram -or $settings.channels.discord)) { $problems.Add('no channel is enabled') | Out-Null }
    foreach ($name in @('telegram','discord')) { if ($settings.channels.$name) { $reason = Get-HarnessMissingSecretReason $name; if ($reason) { $problems.Add($reason) | Out-Null } } }
    foreach ($eventName in @('stop','budget','completion')) { if (-not $settings.events.$eventName) { $problems.Add("the '$eventName' event is off") | Out-Null } }
    $live = New-Object 'System.Collections.Generic.List[string]'
    if ($settings.channels.telegram -and -not (Get-HarnessMissingSecretReason 'telegram') -and [string]::IsNullOrWhiteSpace($env:HARNESS_NOTIFY_CAPTURE_FILE)) {
        # getMe and getChat read the bot and chat without sending anything.
        $api = 'https://api.telegram.org/bot' + $env:HARNESS_TELEGRAM_BOT_TOKEN
        try { $me = Invoke-RestMethod -Method Get -Uri ($api + '/getMe') -TimeoutSec 15; $live.Add("telegram bot: ok (@$($me.result.username))") | Out-Null }
        catch { $detail = Get-HarnessNotificationFailureDetail 'telegram' $_; $live.Add("telegram bot: failed - $detail") | Out-Null; $problems.Add("telegram bot check failed") | Out-Null }
        try { $null = Invoke-RestMethod -Method Get -Uri ($api + '/getChat?chat_id=' + [Uri]::EscapeDataString($env:HARNESS_TELEGRAM_CHAT_ID)) -TimeoutSec 15; $live.Add('telegram chat: ok') | Out-Null }
        catch { $detail = Get-HarnessNotificationFailureDetail 'telegram' $_; $live.Add("telegram chat: failed - $detail") | Out-Null; $problems.Add("telegram chat check failed") | Out-Null }
    }
    $recent = @()
    $logPath = Get-HarnessConfiguredPath -RootDir $root -Name 'notification_log' -FallbackRelativePath 'harness/reports/notifications_log.md'
    if (Test-Path -LiteralPath $logPath) {
        $entries = @(([IO.File]::ReadAllText($logPath) -split '(?m)^- time: ') | Select-Object -Skip 1)
        $recent = @($entries | Select-Object -Last 3 | ForEach-Object {
            $lines = $_ -split '\r?\n'
            $value = { param($key) $line = @($lines | Where-Object { $_ -match "^\s+- ${key}: " } | Select-Object -First 1); if ($line.Count) { ($line[0] -replace "^\s+- ${key}: ", '').Trim() } else { '' } }
            [pscustomobject]@{ time = $lines[0].Trim(); channel = (& $value 'provider'); status = (& $value 'status'); detail = (& $value 'detail') }
        })
    }
    $decisionPath = Join-Path (Get-HarnessConfiguredPath -RootDir $root -Name 'notification_state' -FallbackRelativePath 'harness/state/notifications') 'last_status_decision.json'
    $statusDecision = $null
    if (Test-Path -LiteralPath $decisionPath) { try { $statusDecision = [IO.File]::ReadAllText($decisionPath) | ConvertFrom-Json } catch { $statusDecision = $null } }
    $checkReport = [pscustomobject]@{ ready = ($problems.Count -eq 0); problems = $problems.ToArray(); live = $live.ToArray(); recent = $recent; last_status_decision = $statusDecision }
}
$report = [pscustomobject]@{
    settings = $settings
    configured_channels = $targets
    missing_secrets = @(@('telegram','discord') | Where-Object { $settings.channels.$_ -and $targets -notcontains $_ })
    test = $sent
    check = $checkReport
}
if ($Json) { $report | ConvertTo-Json -Depth 6; exit 0 }
Write-Output ("channels: telegram={0} discord={1} (ready: {2})" -f $settings.channels.telegram, $settings.channels.discord, $(if ($targets.Count) { $targets -join ', ' } else { 'none' }))
foreach ($name in $report.missing_secrets) {
    $variables = if ($name -eq 'telegram') { 'HARNESS_TELEGRAM_BOT_TOKEN and HARNESS_TELEGRAM_CHAT_ID' } else { 'HARNESS_DISCORD_WEBHOOK_URL' }
    Write-Output "  $name is enabled but $variables is not set"
}
Write-Output ("events: stop={0} budget={1} completion={2}" -f $settings.events.stop, $settings.events.budget, $settings.events.completion)
Write-Output ("quiet hours: {0} {1}-{2} (messages arrive without sound)" -f $(if ($settings.quiet_hours.enabled) { 'on' } else { 'off' }), $settings.quiet_hours.start, $settings.quiet_hours.end)
Write-Output ("reminders while waiting: every {0} min, up to {1}, wait limit {2} h" -f $settings.reminder.interval_minutes, $settings.reminder.max_count, $settings.reminder.wait_limit_hours)
foreach ($result in $sent) { Write-Output ("test {0}: {1} {2}" -f $result.channel, $result.status, $result.detail) }
if ($null -ne $checkReport) {
    Write-Output ("check: {0}" -f $(if ($checkReport.ready) { 'ready' } else { 'problems found' }))
    foreach ($problem in $checkReport.problems) { Write-Output "  problem: $problem" }
    foreach ($line in $checkReport.live) { Write-Output "  $line" }
    if ($checkReport.recent.Count -eq 0) { Write-Output '  recent log: none' }
    foreach ($entry in $checkReport.recent) { Write-Output ("  recent log: {0} {1} {2} {3}" -f $entry.time, $entry.channel, $entry.status, $entry.detail) }
    if ($null -ne $checkReport.last_status_decision) { Write-Output ("  last status notification: {0} - {1} ({2})" -f $checkReport.last_status_decision.decision, $checkReport.last_status_decision.reason, $checkReport.last_status_decision.decided_at) }
}
