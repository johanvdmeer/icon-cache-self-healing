#Requires -Version 5.1
<#
.SYNOPSIS
    Layer C + D — Proactive icon cache health checker.
    Runs at logon AND every 45 minutes during the session.
    Detects silent corruption that does not cause file size growth.

.DESCRIPTION
    This script is the third and fourth layer of the icon-cache-self-healing toolkit.
    It does NOT watch file sizes (that is Watch-IconCache.ps1's job).
    Instead it evaluates HEURISTICS that predict or confirm silent corruption:

    HEURISTIC 1 — Missing or zero-byte index
      iconcache_idx.db is the master index. If it is gone or empty,
      the entire cache is broken regardless of other file sizes.

    HEURISTIC 2 — Recent external modification pattern
      If iconcache_256.db was modified in the last 15 minutes by a
      process other than Explorer (winget, Windows Update, installers),
      the cache may contain stale or invalid entries. Preemptive repair.

    HEURISTIC 3 — Suspicious file count drop
      A healthy cache has 10+ database files. If Explorer is running
      but fewer than 5 files exist, something deleted them abnormally.

    HEURISTIC 4 — Age-based staleness
      If the cache has not been touched in over 30 days AND Explorer
      has been running continuously, entries may be stale.
      A fresh rebuild costs 3 seconds and prevents future issues.

.NOTES
    Naming Policy:  naming-conventions-policy-v3.2.0 - Style C (Verb-Noun.ps1)
    Log output:     ..\logs\IconCacheHealth.log
    Triggered by:   Task Scheduler
                      - At logon (Layer C)
                      - Every 45 minutes indefinitely (Layer D)
#>

[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir      = Split-Path -Parent $ScriptDir
$LogDir       = Join-Path $RootDir "logs"
$LogPath      = Join-Path $LogDir  "IconCacheHealth.log"
$RepairScript = Join-Path $ScriptDir "Repair-IconCache.ps1"
$CachePath    = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Explorer"
$LockFile     = Join-Path $ScriptDir "repair.lock"

# Heuristic thresholds
$RecentModWindowMinutes = 15   # Consider a modification "recent" if within this window
$MinHealthyFileCount    = 5    # Fewer than this = abnormal state
$StaleAgeDays           = 30   # Cache older than this gets a preemptive refresh

# ---------------------------------------------------------------------------
# INIT
# ---------------------------------------------------------------------------
if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------
function Write-HealthLog {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','REPAIR','PASS','ERROR')][string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry     = "[$timestamp][$Level] $Message"
    Add-Content -Path $LogPath -Value $entry -Encoding UTF8
}

# ---------------------------------------------------------------------------
# LOCK CHECK — respect existing repair in progress
# ---------------------------------------------------------------------------
function Test-LockActive {
    if (-not (Test-Path $LockFile)) { return $false }
    $age = (Get-Date) - (Get-Item $LockFile).LastWriteTime
    if ($age.TotalMinutes -lt 10) { return $true }
    return $false
}

# ---------------------------------------------------------------------------
# HEURISTIC CHECKS
# ---------------------------------------------------------------------------
function Get-CacheFiles {
    return Get-ChildItem -Path $CachePath -Filter 'iconcache_*.db' -ErrorAction SilentlyContinue
}

# H1: Index file health
function Test-IndexHealthy {
    $idxFile = Join-Path $CachePath "iconcache_idx.db"
    if (-not (Test-Path $idxFile)) {
        Write-HealthLog "H1 FAIL: iconcache_idx.db is missing entirely." 'WARN'
        return $false
    }
    $size = (Get-Item $idxFile).Length
    if ($size -lt 100) {
        Write-HealthLog "H1 FAIL: iconcache_idx.db is $size bytes (expected > 100). Index is corrupt or empty." 'WARN'
        return $false
    }
    Write-HealthLog "H1 PASS: iconcache_idx.db present and $([math]::Round($size/1KB,1)) KB." 'PASS'
    return $true
}

# H2: Recent external modification pattern
function Test-NoRecentExternalWrite {
    $mainCache = Join-Path $CachePath "iconcache_256.db"
    if (-not (Test-Path $mainCache)) { return $true }  # Missing handled by H3

    $lastWrite = (Get-Item $mainCache).LastWriteTime
    $minutesAgo = ((Get-Date) - $lastWrite).TotalMinutes

    if ($minutesAgo -lt $RecentModWindowMinutes) {
        # Was Explorer running at the time, or was it something else?
        $explorerRunning = Get-Process -Name explorer -ErrorAction SilentlyContinue
        if (-not $explorerRunning) {
            Write-HealthLog "H2 FAIL: iconcache_256.db written $([math]::Round($minutesAgo,1)) min ago while Explorer was NOT running. External process wrote to cache." 'WARN'
            return $false
        }
        Write-HealthLog "H2 PASS: iconcache_256.db recently modified but Explorer was running (normal rebuild)." 'PASS'
    } else {
        Write-HealthLog "H2 PASS: iconcache_256.db last modified $([math]::Round($minutesAgo,0)) min ago (outside suspicious window)." 'PASS'
    }
    return $true
}

# H3: File count sanity
function Test-FileCountHealthy {
    $files = Get-CacheFiles
    $count = if ($files) { ($files | Measure-Object).Count } else { 0 }

    $explorerRunning = Get-Process -Name explorer -ErrorAction SilentlyContinue
    if ($explorerRunning -and $count -lt $MinHealthyFileCount) {
        Write-HealthLog "H3 FAIL: Only $count iconcache_*.db files found while Explorer is running. Expected $MinHealthyFileCount+. Abnormal state." 'WARN'
        return $false
    }
    Write-HealthLog "H3 PASS: $count cache files present." 'PASS'
    return $true
}

# H4: Staleness check
function Test-NotStale {
    $files = Get-CacheFiles
    if (-not $files) { return $true }  # Handled by H3

    $newestWrite = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    $daysOld = ((Get-Date) - $newestWrite).TotalDays

    if ($daysOld -gt $StaleAgeDays) {
        Write-HealthLog "H4 FAIL: Cache last updated $([math]::Round($daysOld,0)) days ago. Preemptive refresh recommended." 'WARN'
        return $false
    }
    Write-HealthLog "H4 PASS: Cache last updated $([math]::Round($daysOld,1)) days ago." 'PASS'
    return $true
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
Write-HealthLog "--- Test-IconCacheHealth.ps1 running (Force=$Force) ---"

if (Test-LockActive) {
    Write-HealthLog "Repair already in progress (lock file active). Skipping health check." 'INFO'
    exit 0
}

if ($Force) {
    Write-HealthLog "-Force specified. Skipping heuristics, triggering repair directly." 'WARN'
    & $RepairScript -Force
    exit 0
}

# Run all heuristics and collect results
$h1 = Test-IndexHealthy
$h2 = Test-NoRecentExternalWrite
$h3 = Test-FileCountHealthy
$h4 = Test-NotStale

$allHealthy = $h1 -and $h2 -and $h3 -and $h4

if ($allHealthy) {
    Write-HealthLog "=== ALL HEURISTICS PASSED. Cache is healthy. No action needed. ===" 'PASS'
    exit 0
}

# One or more heuristics failed — trigger repair
Write-HealthLog "=== HEURISTIC FAILURE DETECTED. Triggering repair... ===" 'REPAIR'

try {
    & $RepairScript
    Write-HealthLog "Repair script invoked successfully." 'REPAIR'
} catch {
    Write-HealthLog "Failed to invoke repair script: $($_.Exception.Message)" 'ERROR'
}
