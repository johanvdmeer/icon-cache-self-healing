#Requires -Version 5.1
<#
.SYNOPSIS
    Repairs the Windows 11 icon cache by safely clearing stale database files
    and triggering a clean rebuild via Explorer restart.

.DESCRIPTION
    This script is the shared core logic for the icon-cache-self-healing toolkit.
    It can be called:
      - Directly (manual / smoke test):  .\Repair-IconCache.ps1 -Force
      - By Task Scheduler (Solution A):  triggered on Event ID 1000/1002
      - By Watch-IconCache.ps1 (Solution B): triggered on file-size threshold

    The script is idempotent and safe to run multiple times. A lock file prevents
    concurrent executions from conflicting.

.PARAMETER SizeLimitMB
    Only repair if the total icon cache size exceeds this threshold (MB).
    Default: 256. Ignored when -Force is specified.

.PARAMETER Force
    Skip the size/health check and always perform the repair.
    Use this for manual testing or guaranteed cleanup.

.PARAMETER IncludeThumbcache
    Also delete thumbcache_*.db files (thumbnail database). Thumbnails will
    take longer to rebuild. Off by default.

.NOTES
    Naming Policy:  naming-conventions-policy-v3.2.0 — Style C (Verb-Noun.ps1)
    Log output:     ..\logs\IconCacheRepair.log (relative to script location)
    Lock file:      ..\scripts\repair.lock
    Requires:       No elevation needed for cache deletion (user-scope files).
                    Elevation IS required for Task Scheduler registration
                    (handled by Register-Tasks.ps1, not this script).

.EXAMPLE
    # Manual forced repair
    .\Repair-IconCache.ps1 -Force

.EXAMPLE
    # Repair only if cache exceeds 128 MB
    .\Repair-IconCache.ps1 -SizeLimitMB 128
#>

[CmdletBinding()]
param(
    [int]   $SizeLimitMB      = 256,
    [switch]$Force,
    [switch]$IncludeThumbcache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir     = Split-Path -Parent $ScriptDir
$LogDir      = Join-Path $RootDir "logs"
$LogPath     = Join-Path $LogDir  "IconCacheRepair.log"
$LockFile    = Join-Path $ScriptDir "repair.lock"
$CachePath   = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Explorer"
$LockTimeoutMinutes = 10

# ---------------------------------------------------------------------------
# INIT — ensure log directory exists
# ---------------------------------------------------------------------------
if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','REPAIR')][string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry     = "[$timestamp][$Level] $Message"
    Add-Content -Path $LogPath -Value $entry -Encoding UTF8
    # Also write to host for manual runs (suppressed by Task Scheduler)
    Write-Verbose $entry
}

# ---------------------------------------------------------------------------
# LOCK — prevent concurrent runs
# ---------------------------------------------------------------------------
function Test-LockActive {
    if (-not (Test-Path $LockFile)) { return $false }
    $age = (Get-Date) - (Get-Item $LockFile).LastWriteTime
    if ($age.TotalMinutes -lt $LockTimeoutMinutes) {
        Write-Log "Lock file active (age: $([math]::Round($age.TotalMinutes,1)) min). Skipping run." 'WARN'
        return $true
    }
    Write-Log "Stale lock file found (age: $([math]::Round($age.TotalMinutes,1)) min). Clearing." 'WARN'
    Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    return $false
}

function Set-Lock   { New-Item -Path $LockFile -ItemType File -Force | Out-Null }
function Clear-Lock { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
# HEALTH CHECK — is repair actually needed?
# ---------------------------------------------------------------------------
function Get-CacheSizeMB {
    $files = Get-ChildItem -Path $CachePath -Filter 'iconcache_*.db' -ErrorAction SilentlyContinue
    if (-not $files) { return 0 }
    return [math]::Round(($files | Measure-Object -Property Length -Sum).Sum / 1MB, 2)
}

function Test-RepairNeeded {
    $sizeMB = Get-CacheSizeMB
    Write-Log "Current icon cache size: $sizeMB MB (threshold: $SizeLimitMB MB)"

    $cacheFiles = Get-ChildItem -Path $CachePath -Filter 'iconcache_*.db' -ErrorAction SilentlyContinue
    if (-not $cacheFiles) {
        Write-Log "No iconcache_*.db files found — cache is either pristine or already cleared." 'WARN'
        return $false
    }

    if ($sizeMB -gt $SizeLimitMB) {
        Write-Log "Cache exceeds limit ($sizeMB MB > $SizeLimitMB MB). Repair required." 'WARN'
        return $true
    }

    Write-Log "Cache is healthy ($sizeMB MB). No action needed."
    return $false
}

# ---------------------------------------------------------------------------
# CORE REPAIR LOGIC
# ---------------------------------------------------------------------------
function Invoke-Repair {
    Write-Log "=== REPAIR STARTED ===" 'REPAIR'
    Write-Log "Parameters: SizeLimitMB=$SizeLimitMB Force=$Force IncludeThumbcache=$IncludeThumbcache" 'REPAIR'

    $sizeBefore = Get-CacheSizeMB
    $deletedCount = 0

    try {
        # 1. Stop Explorer gracefully
        Write-Log "Stopping explorer.exe..."
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        # 2. Delete iconcache_*.db files
        $iconFiles = Get-ChildItem -Path $CachePath -Filter 'iconcache_*.db' -ErrorAction SilentlyContinue
        foreach ($file in $iconFiles) {
            try {
                Remove-Item $file.FullName -Force
                Write-Log "Deleted: $($file.Name) ($([math]::Round($file.Length / 1KB, 1)) KB)"
                $deletedCount++
            } catch {
                Write-Log "Could not delete: $($file.Name) — $($_.Exception.Message)" 'ERROR'
            }
        }

        # 3. Optionally delete thumbcache_*.db
        if ($IncludeThumbcache) {
            Write-Log "IncludeThumbcache: deleting thumbcache_*.db files..."
            $thumbFiles = Get-ChildItem -Path $CachePath -Filter 'thumbcache_*.db' -ErrorAction SilentlyContinue
            foreach ($file in $thumbFiles) {
                try {
                    Remove-Item $file.FullName -Force
                    Write-Log "Deleted thumbcache: $($file.Name)"
                    $deletedCount++
                } catch {
                    Write-Log "Could not delete thumbcache: $($file.Name) — $($_.Exception.Message)" 'ERROR'
                }
            }
        }

        # 4. Signal Windows Shell to reset icon cache index
        $ie4uinit = Join-Path $env:SystemRoot 'System32\ie4uinit.exe'
        if (Test-Path $ie4uinit) {
            & $ie4uinit -show 2>$null
            Write-Log "ie4uinit.exe -show executed (shell icon index reset)."
        }

        # 5. Restart Explorer
        Write-Log "Restarting explorer.exe..."
        Start-Process explorer.exe
        Start-Sleep -Seconds 3

        $sizeAfter = Get-CacheSizeMB
        Write-Log "=== REPAIR COMPLETE — $deletedCount file(s) deleted | Before: $sizeBefore MB | After: $sizeAfter MB ===" 'REPAIR'

    } catch {
        Write-Log "CRITICAL ERROR during repair: $($_.Exception.Message)" 'ERROR'
        Write-Log "Stack trace: $($_.ScriptStackTrace)" 'ERROR'
        # Ensure Explorer is running even if repair failed
        $explorerRunning = Get-Process -Name explorer -ErrorAction SilentlyContinue
        if (-not $explorerRunning) {
            Start-Process explorer.exe
            Write-Log "Explorer restarted after error recovery." 'WARN'
        }
    }
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
Write-Log "--- Repair-IconCache.ps1 invoked ---"

if (Test-LockActive) {
    exit 0
}

Set-Lock

try {
    if ($Force) {
        Write-Log "-Force specified. Skipping health check."
        Invoke-Repair
    } elseif (Test-RepairNeeded) {
        Invoke-Repair
    } else {
        Write-Log "No repair needed. Exiting cleanly."
    }
} finally {
    Clear-Lock
}
