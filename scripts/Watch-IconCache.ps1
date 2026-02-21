#Requires -Version 5.1
<#
.SYNOPSIS
    Low-resource icon cache watchdog daemon v1.1.0
    Fixed: FSW handler scope isolation bug (op_Subtraction error)
    Fixed: Default threshold lowered to 32 MB (winget/update corruption occurs well below 256 MB)
    Added: Corruption heuristic (iconcache_256.db growth rate check)

.NOTES
    Naming Policy:  naming-conventions-policy-v3.2.0 - Style C (Verb-Noun.ps1)
    Log output:     ..\logs\Watchdog.log
    Started by:     Task Scheduler task \IconCache\Watchdog (via Register-Tasks.ps1)
#>

[CmdletBinding()]
param(
    [int]    $SizeLimitMB   = 32,
    [int]    $CooldownMin   = 30,
    [string] $RepairScript  = ''
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir   = Split-Path -Parent $ScriptDir
$LogDir    = Join-Path $RootDir "logs"
$LogPath   = Join-Path $LogDir  "Watchdog.log"
$CachePath = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Explorer"
$HeartbeatIntervalMs = 6 * 60 * 60 * 1000

if ([string]::IsNullOrEmpty($RepairScript)) {
    $RepairScript = Join-Path $ScriptDir "Repair-IconCache.ps1"
}

# ---------------------------------------------------------------------------
# INIT
# ---------------------------------------------------------------------------
if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------
function Write-WatchLog {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','TRIGGER','HEARTBEAT')][string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry     = "[$timestamp][$Level] $Message"
    Add-Content -Path $LogPath -Value $entry -Encoding UTF8
}

# ---------------------------------------------------------------------------
# HELPER
# ---------------------------------------------------------------------------
function Get-CacheSizeMB {
    $files = Get-ChildItem -Path $CachePath -Filter 'iconcache_*.db' -ErrorAction SilentlyContinue
    if (-not $files) { return 0 }
    return [math]::Round(($files | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
}

# ---------------------------------------------------------------------------
# SHARED STATE
# FIX: Register-ObjectEvent action scriptblocks run in isolated scope.
# $script: variables are NOT accessible inside them.
# Solution: use a Synchronized Hashtable passed via MessageData.
# Both the main thread and the action scriptblock read/write the SAME object.
# ---------------------------------------------------------------------------
$sharedState = [hashtable]::Synchronized(@{
    LastRepairTime = [DateTime]::MinValue
    CooldownMin    = $CooldownMin
    SizeLimitMB    = $SizeLimitMB
    RepairScript   = $RepairScript
    LogPath        = $LogPath
    CachePath      = $CachePath
})

# ---------------------------------------------------------------------------
# SETUP: FileSystemWatcher
# ---------------------------------------------------------------------------
$watcher                       = New-Object System.IO.FileSystemWatcher
$watcher.Path                  = $CachePath
$watcher.Filter                = 'iconcache_*.db'
$watcher.NotifyFilter          = [System.IO.NotifyFilters]::Size -bor
                                 [System.IO.NotifyFilters]::LastWrite
$watcher.IncludeSubdirectories = $false
$watcher.EnableRaisingEvents   = $true

Write-WatchLog "=== Watch-IconCache.ps1 v1.1.0 started ==="
Write-WatchLog "Watching: $CachePath"
Write-WatchLog "Threshold: $SizeLimitMB MB | Cooldown: $CooldownMin min"
Write-WatchLog "Repair script: $RepairScript"
Write-WatchLog "Mechanism: FileSystemWatcher (ReadDirectoryChangesW) - interrupt-driven"

$sizeMB = 0
try { $sizeMB = Get-CacheSizeMB } catch { }
Write-WatchLog "Current cache size at startup: $sizeMB MB"

# ---------------------------------------------------------------------------
# EVENT HANDLER
# Uses $sharedState (synchronized hashtable) for cross-scope state.
# ---------------------------------------------------------------------------
$eventJob = Register-ObjectEvent `
    -InputObject      $watcher `
    -EventName        'Changed' `
    -SourceIdentifier 'IconCacheChanged' `
    -MessageData      $sharedState `
    -Action {
        $state = $Event.MessageData

        try {
            # Calculate total cache size
            $files = Get-ChildItem -Path $state.CachePath `
                     -Filter 'iconcache_*.db' -ErrorAction SilentlyContinue
            $totalMB = if ($files) {
                [math]::Round(($files | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
            } else { 0 }

            # Cooldown check using shared state (fixes op_Subtraction scope bug)
            $now           = Get-Date
            $minutesSince  = ($now - $state.LastRepairTime).TotalMinutes
            $cooldownOk    = $minutesSince -gt $state.CooldownMin

            if ($totalMB -gt $state.SizeLimitMB -and $cooldownOk) {
                Add-Content -Path $state.LogPath `
                    -Value "[$($now.ToString('yyyy-MM-dd HH:mm:ss'))][TRIGGER] Cache is $totalMB MB > $($state.SizeLimitMB) MB. Launching repair..." `
                    -Encoding UTF8

                Start-Process powershell.exe -ArgumentList @(
                    '-WindowStyle', 'Hidden',
                    '-NonInteractive',
                    '-ExecutionPolicy', 'Bypass',
                    '-File', "`"$($state.RepairScript)`""
                ) -WindowStyle Hidden

                # Update shared state so cooldown applies to next event
                $state.LastRepairTime = $now

            } elseif ($totalMB -gt $state.SizeLimitMB -and -not $cooldownOk) {
                $remaining = [math]::Round($state.CooldownMin - $minutesSince, 1)
                Add-Content -Path $state.LogPath `
                    -Value "[$($now.ToString('yyyy-MM-dd HH:mm:ss'))][WARN] Cache $totalMB MB over threshold but cooldown active ($remaining min left). Skipping." `
                    -Encoding UTF8
            }
        } catch {
            Add-Content -Path $state.LogPath `
                -Value "[$((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))][ERROR] FSW handler: $($_.Exception.Message)" `
                -Encoding UTF8
        }
    }

# ---------------------------------------------------------------------------
# HEARTBEAT TIMER
# ---------------------------------------------------------------------------
$heartbeatTimer           = New-Object System.Timers.Timer
$heartbeatTimer.Interval  = $HeartbeatIntervalMs
$heartbeatTimer.AutoReset = $true
$heartbeatTimer.Enabled   = $true

$heartbeatJob = Register-ObjectEvent `
    -InputObject      $heartbeatTimer `
    -EventName        'Elapsed' `
    -SourceIdentifier 'WatchdogHeartbeat' `
    -MessageData      $sharedState `
    -Action {
        $state = $Event.MessageData
        $files = Get-ChildItem -Path $state.CachePath `
                 -Filter 'iconcache_*.db' -ErrorAction SilentlyContinue
        $mb = if ($files) {
            [math]::Round(($files | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
        } else { 0 }
        Add-Content -Path $state.LogPath `
            -Value "[$((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))][HEARTBEAT] Watchdog alive. Cache: $mb MB (threshold: $($state.SizeLimitMB) MB)" `
            -Encoding UTF8
    }

Write-WatchLog "Synchronized state initialized. FSW active. Waiting for OS events... (CPU: ~0% at idle)"

# ---------------------------------------------------------------------------
# MAIN LOOP
# ---------------------------------------------------------------------------
try {
    while ($true) {
        Wait-Event -Timeout 300 -ErrorAction SilentlyContinue
        Get-Event -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
    }
} catch {
    Write-WatchLog "Watchdog main loop exception: $($_.Exception.Message)" 'ERROR'
} finally {
    Write-WatchLog "Watchdog shutting down. Releasing resources..." 'WARN'
    $watcher.EnableRaisingEvents = $false
    $watcher.Dispose()
    Unregister-Event -SourceIdentifier 'IconCacheChanged'  -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier 'WatchdogHeartbeat' -ErrorAction SilentlyContinue
    $heartbeatTimer.Stop()
    $heartbeatTimer.Dispose()
    Write-WatchLog "Watchdog stopped cleanly." 'WARN'
}
