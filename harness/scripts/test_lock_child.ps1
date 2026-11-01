param(
    [Parameter(Mandatory=$true)][string]$CommonPath,
    [Parameter(Mandatory=$true)][string]$LockRoot,
    [Parameter(Mandatory=$true)][string]$LockName,
    [Parameter(Mandatory=$true)][string]$SignalPath,
    [string]$StartSignal = '',
    [int]$HoldMilliseconds = 30000
)
$ErrorActionPreference = 'Stop'
# Tests never send real notifications: drop the operator's notification secrets (F-26).
foreach ($harnessNotifySecret in @('HARNESS_TELEGRAM_BOT_TOKEN', 'HARNESS_TELEGRAM_CHAT_ID', 'HARNESS_DISCORD_WEBHOOK_URL', 'HARNESS_NOTIFY_PROVIDER')) { [Environment]::SetEnvironmentVariable($harnessNotifySecret, $null, 'Process') }
. $CommonPath
if ($StartSignal) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $StartSignal)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'start signal timeout' }
        Start-Sleep -Milliseconds 25
    }
}
$lease = Acquire-HarnessLock $LockRoot $LockName
if ($null -eq $lease) { Write-Utf8File $SignalPath 'blocked'; exit 0 }
try {
    Write-Utf8File $SignalPath 'acquired'
    Start-Sleep -Milliseconds $HoldMilliseconds
} finally { Release-HarnessLock $lease }
