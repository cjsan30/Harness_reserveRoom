param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'harness_common.ps1')
$source=Split-Path -Parent $PSScriptRoot
if(-not $OutputDirectory){$OutputDirectory=Join-Path $source '.test-output'}
$testRoot=Join-Path $OutputDirectory ([Guid]::NewGuid().ToString('N'));Ensure-HarnessDirectory $testRoot
$results=New-Object 'System.Collections.Generic.List[object]'
function Assert-True($Value,[string]$Message){if(-not $Value){throw $Message}}
function Reject([scriptblock]$Body){$blocked=$false;try{& $Body|Out-Null}catch{$blocked=$true};Assert-True $blocked 'expected rejection'}
function Case([string]$Kind,[string]$Name,[scriptblock]$Body){try{& $Body;$results.Add(@{kind=$Kind;name=$Name;passed=$true});Write-Output "PASS [$Kind] $Name"}catch{$results.Add(@{kind=$Kind;name=$Name;passed=$false;error=$_.Exception.Message});Write-Output "FAIL [$Kind] $Name : $($_.Exception.Message)"}}
function Fixture{
    $root=Join-Path $testRoot ('notify [safe] '+[Guid]::NewGuid().ToString('N'))
    Write-Utf8File (Join-Path $root 'harness/project/configs/project_profile.json') '{"project":{"name":"fixture-project"}}'
    return $root
}
# Fake secrets; the capture file replaces the network.
$fakeToken='123456:fake-telegram-token-value'
$fakeHook='https://discord.com/api/webhooks/1/fake-discord-hook-secret'
$names=@('HARNESS_TELEGRAM_BOT_TOKEN','HARNESS_TELEGRAM_CHAT_ID','HARNESS_DISCORD_WEBHOOK_URL','HARNESS_NOTIFY_CAPTURE_FILE','HARNESS_NOTIFY_DISABLED')
$saved=@{};foreach($n in $names){$saved[$n]=[Environment]::GetEnvironmentVariable($n)}
function Use-Env([hashtable]$Values){foreach($n in $names){[Environment]::SetEnvironmentVariable($n,$(if($Values.ContainsKey($n)){$Values[$n]}else{$null}))}}
function Captured([string]$Path){if(-not (Test-Path -LiteralPath $Path)){return @()};return @([IO.File]::ReadAllLines($Path)|Where-Object{$_}|ForEach-Object{$_|ConvertFrom-Json})}
try {
Case unit 'defaults apply without a settings file and changes round-trip' {
    $root=Fixture;$s=Get-HarnessNotificationSettings $root
    Assert-True ($s.events.stop -and $s.events.budget -and -not $s.events.completion -and -not $s.quiet_hours.enabled -and $s.reminder.interval_minutes -eq 120) 'unexpected defaults'
    $s.quiet_hours.enabled=$true;$s.quiet_hours.start='22:30';$s.reminder.max_count=3;$s.channels.discord=$false
    Save-HarnessNotificationSettings $root $s
    $r=Get-HarnessNotificationSettings $root
    Assert-True ($r.quiet_hours.enabled -and $r.quiet_hours.start -eq '22:30' -and $r.reminder.max_count -eq 3 -and -not $r.channels.discord) 'settings did not round-trip'
    Assert-True (-not ([IO.File]::ReadAllText((Get-HarnessNotificationSettingsPath $root))).Contains('token')) 'settings file mentions secrets'
}
Case security 'invalid settings are refused' {
    foreach($mutate in @({param($s)$s.quiet_hours.start='24:00'},{param($s)$s.quiet_hours.end='7:00'},{param($s)$s.reminder.interval_minutes=5},{param($s)$s.reminder.wait_limit_hours=100},{param($s)$s.events.stop='yes'},{param($s)$s|Add-Member webhook 'x'})){
        $s=New-HarnessDefaultNotificationSettings;& $mutate $s
        Reject {Save-HarnessNotificationSettings (Fixture) $s}
    }
    $root=Fixture;Write-Utf8File (Get-HarnessNotificationSettingsPath $root) '{broken'
    Reject {Get-HarnessNotificationSettings $root}
}
Case unit 'quiet hours handle windows that cross midnight' {
    $s=New-HarnessDefaultNotificationSettings;$s.quiet_hours.enabled=$true
    Assert-True ((Test-HarnessQuietTime $s ([DateTime]'2026-10-28 23:30')) -and (Test-HarnessQuietTime $s ([DateTime]'2026-10-28 07:59'))) 'night not quiet'
    Assert-True (-not (Test-HarnessQuietTime $s ([DateTime]'2026-10-28 08:00')) -and -not (Test-HarnessQuietTime $s ([DateTime]'2026-10-28 12:00'))) 'day treated as quiet'
    $s.quiet_hours.start='13:00';$s.quiet_hours.end='14:00'
    Assert-True ((Test-HarnessQuietTime $s ([DateTime]'2026-10-28 13:15')) -and -not (Test-HarnessQuietTime $s ([DateTime]'2026-10-28 14:15'))) 'same-day window wrong'
}
Case integration 'a stop is sent to every configured channel, silently during quiet hours' {
    $root=Fixture;$capture=Join-Path $root 'capture.jsonl'
    Use-Env @{HARNESS_TELEGRAM_BOT_TOKEN=$fakeToken;HARNESS_TELEGRAM_CHAT_ID='42';HARNESS_DISCORD_WEBHOOK_URL=$fakeHook;HARNESS_NOTIFY_CAPTURE_FILE=$capture}
    $s=Get-HarnessNotificationSettings $root;$s.quiet_hours.enabled=$true;Save-HarnessNotificationSettings $root $s
    $text=Format-HarnessStopNotification 'fixture-project' 'needs_operator' 'task-1' ("permission problem; leaked $fakeToken") 'plan.md'
    $sent=@(Send-HarnessNotification $root 'stop' $text ([DateTime]'2026-10-28 23:30'))
    $got=@(Captured $capture)
    Assert-True ($sent.Count -eq 2 -and @($sent|Where-Object{$_.status -ne 'sent'}).Count -eq 0) "send results wrong: $($sent|ConvertTo-Json -Compress)"
    Assert-True ($got.Count -eq 2 -and @($got|Where-Object{-not $_.silent}).Count -eq 0) 'quiet hours did not deliver silently'
    Assert-True ($got[0].text.Contains('사용자 확인 필요') -and $got[0].text.Contains('task-1') -and -not $got[0].text.Contains($fakeToken)) "message wrong or secret leaked: $($got[0].text)"
    $log=[IO.File]::ReadAllText((Join-Path $root 'harness/reports/notifications_log.md'))
    Assert-True (-not $log.Contains($fakeToken) -and -not $log.Contains('fake-discord-hook-secret') -and $log.Contains('event: stop')) 'log leaked a secret or lacks the event'
    $null=Send-HarnessNotification $root 'stop' $text ([DateTime]'2026-10-28 12:00')
    Assert-True (-not @(Captured $capture)[2].silent) 'daytime message was silent'
}
Case integration 'disabled events, channels without secrets and the kill switch send nothing' {
    $root=Fixture;$capture=Join-Path $root 'capture.jsonl'
    Use-Env @{HARNESS_TELEGRAM_BOT_TOKEN=$fakeToken;HARNESS_NOTIFY_CAPTURE_FILE=$capture}
    Assert-True (@(Send-HarnessNotification $root 'stop' 'x').Count -eq 0) 'telegram without chat id was used'
    Use-Env @{HARNESS_TELEGRAM_BOT_TOKEN=$fakeToken;HARNESS_TELEGRAM_CHAT_ID='42';HARNESS_NOTIFY_CAPTURE_FILE=$capture}
    Assert-True (@(Send-HarnessNotification $root 'completion' 'x').Count -eq 0) 'completion sent while disabled by default'
    $s=Get-HarnessNotificationSettings $root;$s.channels.telegram=$false;Save-HarnessNotificationSettings $root $s
    Assert-True (@(Send-HarnessNotification $root 'stop' 'x').Count -eq 0) 'disabled channel was used'
    $s.channels.telegram=$true;Save-HarnessNotificationSettings $root $s
    Use-Env @{HARNESS_TELEGRAM_BOT_TOKEN=$fakeToken;HARNESS_TELEGRAM_CHAT_ID='42';HARNESS_NOTIFY_CAPTURE_FILE=$capture;HARNESS_NOTIFY_DISABLED='true'}
    Assert-True (@(Send-HarnessNotification $root 'stop' 'x').Count -eq 0 -and @(Captured $capture).Count -eq 0) 'kill switch ignored'
    Reject {Send-HarnessNotification $root 'anything' 'x'}
}
Case security 'a bad Discord URL fails alone without leaking it' {
    $root=Fixture;$capture=Join-Path $root 'capture.jsonl'
    Use-Env @{HARNESS_TELEGRAM_BOT_TOKEN=$fakeToken;HARNESS_TELEGRAM_CHAT_ID='42';HARNESS_DISCORD_WEBHOOK_URL='https://evil.example/hook/secret-path-value';HARNESS_NOTIFY_CAPTURE_FILE=$capture}
    $sent=@(Send-HarnessNotification $root 'budget' 'limit')
    $discord=@($sent|Where-Object{$_.channel -eq 'discord'})[0];$telegram=@($sent|Where-Object{$_.channel -eq 'telegram'})[0]
    Assert-True ($discord.status -eq 'failed' -and $telegram.status -eq 'sent') 'one channel failure blocked the other or was accepted'
    Assert-True (-not ($sent|ConvertTo-Json -Depth 4).Contains('secret-path-value')) 'URL leaked in the result'
}
Case unit 'messages name the stop kind and the next step, and long reasons are cut' {
    $budget=Format-HarnessStopNotification 'p' 'budget' 'task-1' 'execution budget reached: max_invocations (12 of 12 invocations used)' 'plan.md'
    Assert-True ($budget.Contains('비용 한도 도달') -and $budget.Contains('12 of 12') -and $budget.Contains('harness.ps1 usage')) "budget message wrong: $budget"
    $repeat=Format-HarnessStopNotification 'p' 'repeated_failure' 'task-1' ('x'*900) 'plan.md'
    Assert-True ($repeat.Contains('harness/state/failures/task-1.md') -and $repeat.Length -lt 800) 'repeat message wrong or too long'
}
Case integration 'the notify command changes settings and a test message restores them' {
    $root=Join-Path $testRoot ('notify cli [safe] '+[Guid]::NewGuid().ToString('N'));$engine=Join-Path $root 'harness'
    Ensure-HarnessDirectory $engine
    foreach($dir in @('scripts','configs')){Copy-Item -LiteralPath (Join-Path $source $dir) -Destination (Join-Path $engine $dir) -Recurse}
    Write-Utf8File (Join-Path $engine 'project/configs/project_profile.json') '{"project":{"name":"cli-project"}}'
    $capture=Join-Path $root 'capture.jsonl'
    Use-Env @{HARNESS_DISCORD_WEBHOOK_URL=$fakeHook;HARNESS_NOTIFY_CAPTURE_FILE=$capture}
    $old=$env:CODEX_HARNESS_ROOT
    try{
        $env:CODEX_HARNESS_ROOT=$root
        $r=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/manage_notifications.ps1') @('-OnStop','off','-QuietHours','on','-QuietStart','22:00','-ReminderMinutes','60') -AllowFailure
        Assert-True $r.Success $r.Output
        $s=Get-HarnessNotificationSettings $root
        Assert-True (-not $s.events.stop -and $s.quiet_hours.enabled -and $s.quiet_hours.start -eq '22:00' -and $s.reminder.interval_minutes -eq 60) 'settings not changed'
        Assert-True ($r.Output.Contains('telegram is enabled but HARNESS_TELEGRAM_BOT_TOKEN')) 'missing secret not reported'
        $t=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/manage_notifications.ps1') @('-Test') -AllowFailure
        Assert-True ($t.Success -and @(Captured $capture).Count -eq 1 -and @(Captured $capture)[0].text.Contains('알림 테스트')) "test not sent: $($t.Output)"
        Assert-True (-not (Get-HarnessNotificationSettings $root).events.stop) 'test message left the stop event enabled'
        $bad=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/manage_notifications.ps1') @('-QuietStart','25:00') -AllowFailure
        Assert-True (-not $bad.Success -and (Get-HarnessNotificationSettings $root).quiet_hours.start -eq '22:00') 'invalid time saved'
    }finally{$env:CODEX_HARNESS_ROOT=$old}
}
} finally { foreach($n in $names){[Environment]::SetEnvironmentVariable($n,$saved[$n])} }

Write-Utf8File (Join-Path $testRoot 'results.json') ($results.ToArray()|ConvertTo-Json -Depth 8)
$failed=@($results|Where-Object{-not $_.passed}).Count
Write-Output "Notification results: $($results.Count-$failed)/$($results.Count) passed; artifacts: $testRoot"
if($failed){exit 1}
