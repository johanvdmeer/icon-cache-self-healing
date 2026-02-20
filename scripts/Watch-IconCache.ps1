#Requires -Version 5.1
<#
.SYNOPSIS
    Low-resource icon cache watchdog daemon. Monitors iconcache_*.db file sizes
    using interrupt-based FileSystemWatcher (not polling). Triggers repair when
    the total cache size exceeds the configured threshold.

.DESCRIPTION
    Solution B of the icon-cache-self-healing toolkit.

    This script runs continuously as a background process registered in Task
    Scheduler (see Register-Tasks.ps1). It uses .NET's System.IO.FileSystemWatcher
    class, which wraps the Windows ReadDirectoryChangesW kernel API.

    HOW IT WORKS (Interrupt vs. Polling):
      - The script does NOT loop and check every N seconds (that is polling).
      - Instead, the OS kernel delivers a push notification the moment a watched
        file changes. The PowerShell process sleeps via Wait-Event (a true OS
        wait handle — zero CPU spin) until the OS wakes it.
      - CPU usage at idle: ~0%. Memory: ~15–25 MB (PowerShell process overhead).

    COOLDOWN:
      After a repair fires, the watchdog waits -CooldownMin minutes before it
      will trigger another repair. This prevents rapid repeated repairs if the
      cache rebuilds and immediately grows again.

    HEARTBEAT:
      Every 6 hours, a heartbeat line is written to the watchdog log. This lets
      you verify the daemon is alive without opening Task Manager.

.PARAMETER SizeLimitMB
    Trigger a repair when total iconcache_*.db size exceeds this value (MB).
    Default: 256

.PARAMETER CooldownMin
    Minimum minutes to wait between consecutive repairs. Default: 30

.PARAMETER RepairScript
    Path to Repair-IconCache.ps1. Auto-detected relative to this script's location.

.NOTES
    Naming Policy:  naming-conventions-policy-v3.2.0 — Style C (Verb-Noun.ps1)
    Log output:     ..\logs\Watchdog.log
    Started by:     Task Scheduler task \IconCache\Watchdog (via Register-Tasks.ps1)

.EXAMPLE
    # Normally started by Task Scheduler — but you can run it manually:
    .\Watch-IconCache.ps1 -SizeLimitMB 128 -CooldownMin 60
#>

[CmdletBinding()]
param(
    [int]    $SizeLimitMB   = 256,
    [int]    $CooldownMin   = 30,
    [string] $RepairScript  = ''
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'   # Don't exit on non-fatal errors inside the loop

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir   = Split-Path -Parent $ScriptDir
$LogDir    = Join-Path $RootDir "logs"
$LogPath   = Join-Path $LogDir  "Watchdog.log"
$CachePath = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Explorer"
$HeartbeatIntervalMs = 6 * 60 * 60 * 1000   # 6 hours in milliseconds

# Auto-detect repair script path if not provided
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
# HELPER: get total cache size
# ---------------------------------------------------------------------------
function Get-CacheSizeMB {
    $files = Get-ChildItem -Path $CachePath -Filter 'iconcache_*.db' -ErrorAction SilentlyContinue
    if (-not $files) { return 0 }
    return [math]::Round(($files | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
}

# ---------------------------------------------------------------------------
# SETUP: FileSystemWatcher
# Wraps ReadDirectoryChangesW — interrupt-driven, not polling.
# ---------------------------------------------------------------------------
$watcher                     = New-Object System.IO.FileSystemWatcher
$watcher.Path                = $CachePath
$watcher.Filter              = 'iconcache_*.db'
$watcher.NotifyFilter        = [System.IO.NotifyFilters]::Size -bor
                               [System.IO.NotifyFilters]::LastWrite
$watcher.IncludeSubdirectories = $false
$watcher.EnableRaisingEvents = $true

Write-WatchLog "=== Watch-IconCache.ps1 started ==="
Write-WatchLog "Watching: $CachePath"
Write-WatchLog "Threshold: $SizeLimitMB MB | Cooldown: $CooldownMin min"
Write-WatchLog "Repair script: $RepairScript"
Write-WatchLog "Mechanism: FileSystemWatcher (ReadDirectoryChangesW) — interrupt-driven"

$sizeMB = Get-CacheSizeMB
Write-WatchLog "Current cache size at startup: $sizeMB MB"

# ---------------------------------------------------------------------------
# STATE — shared between event handler and main loop
# ---------------------------------------------------------------------------
$script:LastRepairTime = [DateTime]::MinValue

# ---------------------------------------------------------------------------
# SETUP: FileSystemWatcher event handler
# This scriptblock executes on the PowerShell event thread when the OS
# delivers a file-change notification.
# ---------------------------------------------------------------------------
$messageData = @{
    SizeLimitMB  = $SizeLimitMB
    CooldownMin  = $CooldownMin
    RepairScript = $RepairScript
    LogPath      = $LogPath
    CachePath    = $CachePath
}

$eventJob = Register-ObjectEvent `
    -InputObject       $watcher `
    -EventName         'Changed' `
    -SourceIdentifier  'IconCacheChanged' `
    -MessageData       $messageData `
    -Action {
        $cfg = $Event.MessageData

        try {
            # Calculate total size
            $files = Get-ChildItem -Path $cfg.CachePath -Filter 'iconcache_*.db' -ErrorAction SilentlyContinue
            $totalMB = if ($files) {
                [math]::Round(($files | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
            } else { 0 }

            # Check cooldown
            $cooldownOk = ($Event.TimeGenerated - $script:LastRepairTime).TotalMinutes -gt $cfg.CooldownMin

            if ($totalMB -gt $cfg.SizeLimitMB -and $cooldownOk) {
                Add-Content -Path $cfg.LogPath `
                    -Value "[$((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))][TRIGGER] Cache is $totalMB MB > $($cfg.SizeLimitMB) MB threshold. Launching repair..." `
                    -Encoding UTF8

                # Launch repair as separate process — does not block the watchdog
                Start-Process powershell.exe -ArgumentList @(
                    '-WindowStyle', 'Hidden',
                    '-NonInteractive',
                    '-ExecutionPolicy', 'Bypass',
                    '-File', "`"$($cfg.RepairScript)`""
                ) -WindowStyle Hidden

                $script:LastRepairTime = Get-Date

            } elseif ($totalMB -gt $cfg.SizeLimitMB -and -not $cooldownOk) {
                $remaining = [math]::Round($cfg.CooldownMin - ((Get-Date) - $script:LastRepairTime).TotalMinutes, 1)
                Add-Content -Path $cfg.LogPath `
                    -Value "[$((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))][WARN] Cache is $totalMB MB but cooldown active ($remaining min remaining). Skipping." `
                    -Encoding UTF8
            }
        } catch {
            Add-Content -Path $cfg.LogPath `
                -Value "[$((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))][ERROR] FSW handler: $($_.Exception.Message)" `
                -Encoding UTF8
        }
    }

# ---------------------------------------------------------------------------
# SETUP: Heartbeat timer (proves daemon is alive in the log)
# ---------------------------------------------------------------------------
$heartbeatTimer          = New-Object System.Timers.Timer
$heartbeatTimer.Interval = $HeartbeatIntervalMs
$heartbeatTimer.AutoReset = $true
$heartbeatTimer.Enabled  = $true

$heartbeatJob = Register-ObjectEvent `
    -InputObject      $heartbeatTimer `
    -EventName        'Elapsed' `
    -SourceIdentifier 'WatchdogHeartbeat' `
    -MessageData      @{ LogPath = $LogPath; CachePath = $CachePath } `
    -Action {
        $cfg = $Event.MessageData
        $files = Get-ChildItem -Path $cfg.CachePath -Filter 'iconcache_*.db' -ErrorAction SilentlyContinue
        $mb = if ($files) { [math]::Round(($files | Measure-Object -Property Length -Sum).Sum / 1MB, 2) } else { 0 }
        Add-Content -Path $cfg.LogPath `
            -Value "[$((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))][HEARTBEAT] Watchdog alive. Cache: $mb MB" `
            -Encoding UTF8
    }

Write-WatchLog "FileSystemWatcher active. Waiting for OS events... (CPU: ~0% at idle)"

$sizeMB = 0
try { $sizeMB = Get-CacheSizeMB } catch { }
Write-WatchLog "Current cache size at startup: $sizeMB MB"

# ---------------------------------------------------------------------------
# MAIN LOOP — Wait-Event blocks via OS wait handle (zero CPU spin)
# The loop runs every 5 minutes as a safety net; actual work happens in the
# event handlers above, which fire immediately on file changes.
# ---------------------------------------------------------------------------
try {
    while ($true) {
        # Wait-Event yields the thread to the OS. It wakes when:
        #   a) An event fires (FSW or heartbeat), or
        #   b) The 300-second timeout expires (safety keepalive)
        Wait-Event -Timeout 300 -ErrorAction SilentlyContinue

        # Flush processed events from the queue to prevent memory growth
        Get-Event -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
    }
} catch {
    Write-WatchLog "Watchdog main loop exception: $($_.Exception.Message)" 'ERROR'
} finally {
    # Cleanup — runs when the process is terminated (e.g., by Task Scheduler stop)
    Write-WatchLog "Watchdog shutting down. Releasing resources..." 'WARN'

    $watcher.EnableRaisingEvents = $false
    $watcher.Dispose()

    Unregister-Event -SourceIdentifier 'IconCacheChanged'  -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier 'WatchdogHeartbeat' -ErrorAction SilentlyContinue

    $heartbeatTimer.Stop()
    $heartbeatTimer.Dispose()

    Write-WatchLog "Watchdog stopped cleanly." 'WARN'
}
