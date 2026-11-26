param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
# Tests never send real notifications: drop the operator's notification secrets (F-26).
foreach ($harnessNotifySecret in @('HARNESS_TELEGRAM_BOT_TOKEN', 'HARNESS_TELEGRAM_CHAT_ID', 'HARNESS_DISCORD_WEBHOOK_URL', 'HARNESS_NOTIFY_PROVIDER')) { [Environment]::SetEnvironmentVariable($harnessNotifySecret, $null, 'Process') }
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
Case integration 'disabled events, channels without secrets and the kill switch send nothing and say why' {
    $root=Fixture;$capture=Join-Path $root 'capture.jsonl'
    function Skipped($Results,[string]$Pattern){$r=@($Results);return ($r.Count -ge 1 -and @($r|Where-Object{$_.status -ne 'skipped'}).Count -eq 0 -and @($r|Where-Object{$_.detail -match $Pattern}).Count -ge 1)}
    Use-Env @{HARNESS_TELEGRAM_BOT_TOKEN=$fakeToken;HARNESS_NOTIFY_CAPTURE_FILE=$capture}
    Assert-True (Skipped (Send-HarnessNotification $root 'stop' 'x') 'HARNESS_TELEGRAM_CHAT_ID') 'telegram without chat id was used or not explained'
    Use-Env @{HARNESS_TELEGRAM_BOT_TOKEN=$fakeToken;HARNESS_TELEGRAM_CHAT_ID='42';HARNESS_NOTIFY_CAPTURE_FILE=$capture}
    Assert-True (Skipped (Send-HarnessNotification $root 'completion' 'x') 'notify -OnCompletion on') 'completion sent while disabled by default or not explained'
    $s=Get-HarnessNotificationSettings $root;$s.channels.telegram=$false;$s.channels.discord=$false;Save-HarnessNotificationSettings $root $s
    Assert-True (Skipped (Send-HarnessNotification $root 'stop' 'x') 'no notification channel') 'disabled channel was used or not explained'
    $s.channels.telegram=$true;Save-HarnessNotificationSettings $root $s
    Use-Env @{HARNESS_TELEGRAM_BOT_TOKEN=$fakeToken;HARNESS_TELEGRAM_CHAT_ID='42';HARNESS_NOTIFY_CAPTURE_FILE=$capture;HARNESS_NOTIFY_DISABLED='true'}
    Assert-True ((Skipped (Send-HarnessNotification $root 'stop' 'x') 'HARNESS_NOTIFY_DISABLED') -and @(Captured $capture).Count -eq 0) 'kill switch ignored or not explained'
    $log=[IO.File]::ReadAllText((Join-Path $root 'harness/reports/notifications_log.md'))
    Assert-True (([regex]::Matches($log,'status: skipped')).Count -ge 4 -and -not $log.Contains($fakeToken)) "skips were not logged: $log"
    Reject {Send-HarnessNotification $root 'anything' 'x'}
}
Case unit 'delivery failures name the likely cause' {
    Assert-True ((Get-HarnessNotificationFailureHint 'telegram' 401 '').Contains('HARNESS_TELEGRAM_BOT_TOKEN')) 'bad token not named'
    Assert-True ((Get-HarnessNotificationFailureHint 'telegram' 400 '{"ok":false,"description":"Bad Request: chat not found"}').Contains('/start')) 'unknown chat not named'
    Assert-True ((Get-HarnessNotificationFailureHint 'telegram' 403 'Forbidden: bot was blocked by the user').Contains('blocked')) 'blocked bot not named'
    Assert-True ((Get-HarnessNotificationFailureHint 'telegram' 429 '').Contains('rate limited')) 'rate limit not named'
    Assert-True ((Get-HarnessNotificationFailureHint 'telegram' $null '').StartsWith('network problem')) 'network failure not named'
    Assert-True ((Get-HarnessNotificationFailureHint 'discord' 404 '').Contains('webhook')) 'deleted webhook not named'
}
Case security 'a bad Discord URL fails alone without leaking it' {
    $root=Fixture;$capture=Join-Path $root 'capture.jsonl'
    Use-Env @{HARNESS_TELEGRAM_BOT_TOKEN=$fakeToken;HARNESS_TELEGRAM_CHAT_ID='42';HARNESS_DISCORD_WEBHOOK_URL='https://evil.example/hook/secret-path-value';HARNESS_NOTIFY_CAPTURE_FILE=$capture}
    $sent=@(Send-HarnessNotification $root 'budget' 'limit')
    $discord=@($sent|Where-Object{$_.channel -eq 'discord'})[0];$telegram=@($sent|Where-Object{$_.channel -eq 'telegram'})[0]
    Assert-True ($discord.status -eq 'failed' -and $telegram.status -eq 'sent') 'one channel failure blocked the other or was accepted'
    Assert-True (-not ($sent|ConvertTo-Json -Depth 4).Contains('secret-path-value')) 'URL leaked in the result'
}
Case security 'test suites never inherit real notification secrets' {
    # Field finding F-26: with real Telegram secrets in the environment, fixture preflight
    # failures in the regression were sent to the operator's phone.
    $missing=@(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'test_*.ps1' -File | Where-Object { -not ([IO.File]::ReadAllText($_.FullName)).Contains("SetEnvironmentVariable(`$harnessNotifySecret, `$null, 'Process')") } | ForEach-Object { $_.Name })
    Assert-True ($missing.Count -eq 0) "test suites without the notification guard: $($missing -join ', ')"
    $child=Join-Path $testRoot ('guard '+[Guid]::NewGuid().ToString('N')+'.ps1')
    Write-Utf8File $child ("`$ErrorActionPreference = 'Stop'`n"+([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'test_notifications.ps1')) -split "`n" | Where-Object { $_ -match 'harnessNotifySecret' } | Select-Object -First 1)+"`nWrite-Output ([bool]`$env:HARNESS_TELEGRAM_BOT_TOKEN)")
    $saved=$env:HARNESS_TELEGRAM_BOT_TOKEN
    try{
        $env:HARNESS_TELEGRAM_BOT_TOKEN='123456:fixture-real-looking-token'
        $r=Invoke-HarnessPowerShellFile -FilePath $child -AllowFailure
        Assert-True ($r.Success -and $r.Output.Trim() -eq 'False') "guard left the secret: $($r.Output)"
    }finally{$env:HARNESS_TELEGRAM_BOT_TOKEN=$saved}
}
Case unit 'messages name the stop kind and the next step, and long reasons are cut' {
    $budget=Format-HarnessStopNotification 'p' 'budget' 'task-1' 'execution budget reached: max_invocations (12 of 12 invocations used)' 'plan.md'
    Assert-True ($budget.Contains('비용 한도 도달') -and $budget.Contains('실행 한도 도달 (12/12)') -and $budget.Contains('harness.ps1 usage')) "budget message wrong: $budget"
    $repeat=Format-HarnessStopNotification 'p' 'repeated_failure' 'task-1' ('x'*900) 'plan.md'
    Assert-True ($repeat.Contains('harness/state/failures/task-1.md') -and $repeat.Length -lt 800) 'repeat message wrong or too long'
    $errorText=Format-HarnessStopNotification 'p' 'error' 'none' 'provider reported execution failure' 'plan.md'
    Assert-True ($errorText.Contains('실행 오류로 중단') -and $errorText.Contains('AI 실행 결과가 실패로 보고됨') -and $errorText.Contains('agent_runs')) "error message wrong: $errorText"
}
Case unit 'messages are short Korean templates: known reasons are translated, unknown ones cut' {
    $stop=Format-HarnessStopNotification 'Harness_reserveRoom' 'needs_operator' 'reserve-room-v1__01__schema-foundation' 'stopped (needs_operator) at reserve-room-v1__01__schema-foundation: permission problem: the provider denied tool use' 'plan.md'
    Assert-True ($stop.Contains('작업: 01 schema-foundation') -and $stop.Contains('원인: 권한 문제') -and @($stop -split "`n").Count -le 5 -and $stop -notmatch 'denied tool use') "stop message not short Korean: $stop"
    Assert-True ((ConvertTo-HarnessKoreanReason 'completion has no unique execution evidence; validation required').StartsWith('완료 기록 거부')) 'evidence reason not translated'
    Assert-True ((ConvertTo-HarnessKoreanReason 'The harness refused to record completion because the assignment state is inconsistent').StartsWith('완료 기록 거부')) 'refused completion not translated'
    $unknown=ConvertTo-HarnessKoreanReason ('zzz '+('y'*300))
    Assert-True ($unknown.StartsWith('분류되지 않은 오류: zzz') -and $unknown.Length -lt 130) "unknown reason not cut: $unknown"
}
Case integration 'status-change notification records why it was not sent' {
    $root=Join-Path $testRoot ('notify decision [safe] '+[Guid]::NewGuid().ToString('N'));$engine=Join-Path $root 'harness'
    Ensure-HarnessDirectory $engine
    foreach($dir in @('scripts','configs')){Copy-Item -LiteralPath (Join-Path $source $dir) -Destination (Join-Path $engine $dir) -Recurse}
    Write-Utf8File (Join-Path $engine 'project/configs/project_profile.json') '{"project":{"name":"decision-project"}}'
    Write-Utf8File (Join-Path $engine 'reports/status.json') '{"status":"seed_failed","phase":"seed_handoff","user_action_required":true,"failure":{"type":"unknown","message":"x"}}'
    Use-Env @{}
    $old=$env:CODEX_HARNESS_ROOT
    try{$env:CODEX_HARNESS_ROOT=$root;$r=Invoke-HarnessPowerShellFile -FilePath (Join-Path $engine 'scripts/send_harness_notification.ps1') -Arguments @('-Quiet') -AllowFailure}finally{$env:CODEX_HARNESS_ROOT=$old}
    $decision=[IO.File]::ReadAllText((Join-Path $engine 'state/notifications/last_status_decision.json'))|ConvertFrom-Json
    $log=[IO.File]::ReadAllText((Join-Path $engine 'reports/notifications_log.md'))
    Assert-True ($r.Success -and $decision.decision -eq 'skipped' -and $decision.reason.Contains('provider not configured') -and $log.Contains('status: skipped')) "decision not recorded: $($r.Output)"
}
Case integration 'status-change notification is a short Korean message' {
    $root=Join-Path $testRoot ('notify status [safe] '+[Guid]::NewGuid().ToString('N'));$engine=Join-Path $root 'harness'
    Ensure-HarnessDirectory $engine
    foreach($dir in @('scripts','configs')){Copy-Item -LiteralPath (Join-Path $source $dir) -Destination (Join-Path $engine $dir) -Recurse}
    Write-Utf8File (Join-Path $engine 'project/configs/project_profile.json') '{"project":{"name":"status-project"}}'
    Write-Utf8File (Join-Path $engine 'reports/status.json') '{"status":"preflight_failed","phase":"preflight","user_action_required":true,"failure":{"type":"environment","message":"docker daemon is not running"},"blocking":["preflight failed"],"next_actions":["fix it"]}'
    $old=$env:CODEX_HARNESS_ROOT
    try{
        $env:CODEX_HARNESS_ROOT=$root
        $r=Invoke-HarnessPowerShellFile -FilePath (Join-Path $engine 'scripts/send_harness_notification.ps1') -Arguments @('-Provider','telegram','-DryRun','-Force') -AllowFailure
    }finally{$env:CODEX_HARNESS_ROOT=$old}
    Assert-True ($r.Success -and $r.Output.Contains('[Harness] 사전 점검 실패') -and $r.Output.Contains('원인: 환경 문제') -and $r.Output.Contains('사용자 조치: 필요') -and $r.Output -notmatch 'Attention Required|next_actions') "status message wrong: $($r.Output)"
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
        # -Check explains without sending; capture mode skips the live bot check (no network in tests).
        $c=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/manage_notifications.ps1') @('-Check') -AllowFailure
        Assert-True ($c.Success -and $c.Output.Contains('check: problems found') -and $c.Output.Contains('HARNESS_NOTIFY_CAPTURE_FILE is set') -and $c.Output.Contains("the 'stop' event is off") -and $c.Output.Contains('recent log:') -and @(Captured $capture).Count -eq 1) "check output wrong: $($c.Output)"
        $bad=Invoke-HarnessPowerShellFile (Join-Path $engine 'scripts/manage_notifications.ps1') @('-QuietStart','25:00') -AllowFailure
        Assert-True (-not $bad.Success -and (Get-HarnessNotificationSettings $root).quiet_hours.start -eq '22:00') 'invalid time saved'
    }finally{$env:CODEX_HARNESS_ROOT=$old}
}
} finally { foreach($n in $names){[Environment]::SetEnvironmentVariable($n,$saved[$n])} }

Write-Utf8File (Join-Path $testRoot 'results.json') ($results.ToArray()|ConvertTo-Json -Depth 8)
$failed=@($results|Where-Object{-not $_.passed}).Count
Write-Output "Notification results: $($results.Count-$failed)/$($results.Count) passed; artifacts: $testRoot"
if($failed){exit 1}
