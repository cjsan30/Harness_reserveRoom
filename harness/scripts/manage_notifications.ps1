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
$report = [pscustomobject]@{
    settings = $settings
    configured_channels = $targets
    missing_secrets = @(@('telegram','discord') | Where-Object { $settings.channels.$_ -and $targets -notcontains $_ })
    test = $sent
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
