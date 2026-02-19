# Implementation Guide — icon-cache-self-healing

**Version:** 1.0.0  
**Audience:** Anyone deploying this on a new Windows 11 machine

---

## Prerequisites

| Requirement | Check |
|---|---|
| Windows 10 21H2+ or Windows 11 | `winver` in Run dialog |
| PowerShell 5.1+ | `$PSVersionTable.PSVersion` |
| Administrator account | Required only for installer step |
| ~5 minutes | Total setup time |

---

## Step 1 — Copy the Folder to Your Machine

Place the entire `icon-cache-self-healing` folder anywhere permanent. Recommended:

```
C:\Tools\icon-cache-self-healing\
```

> **Important:** Do not move or rename the folder after installation. The Task Scheduler tasks contain hardcoded paths to the `scripts\` subfolder. If you move the folder, re-run `Register-Tasks.ps1`.

---

## Step 2 — Set Execution Policy (if needed)

Open PowerShell as Administrator:

```powershell
# Check current policy
Get-ExecutionPolicy -List

# If it shows 'Restricted' for LocalMachine or CurrentUser, run:
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
```

> `RemoteSigned` allows locally created scripts to run. It does not disable security — scripts downloaded from the internet still require a signature.

---

## Step 3 — Run the Installer

```powershell
# Open PowerShell as Administrator, then:
cd "C:\Tools\icon-cache-self-healing"
.\scripts\Register-Tasks.ps1
```

The installer will:
1. Create `C:\Tools\icon-cache-self-healing\logs\` if it doesn't exist.
2. Register `\IconCache\EventRepair` in Task Scheduler (Solution A).
3. Register `\IconCache\Watchdog` in Task Scheduler (Solution B).
4. Print a confirmation summary.

**Expected output:**
```
[INSTALLER] icon-cache-self-healing v1.0.0
[OK] Log directory ready: C:\Tools\icon-cache-self-healing\logs
[OK] Task registered: \IconCache\EventRepair  (Event-triggered repair)
[OK] Task registered: \IconCache\Watchdog     (File-size watchdog daemon)
[OK] Starting watchdog now...
[DONE] Installation complete. Both solutions are active.
```

---

## Step 4 — Verify Installation

```powershell
# List registered tasks
Get-ScheduledTask -TaskPath "\IconCache\" | Select-Object TaskName, State

# Expected output:
# TaskName    State
# --------    -----
# EventRepair Ready
# Watchdog    Running
```

---

## Step 5 — Test the Repair Script Manually

```powershell
# Run a forced repair (safe — just clears and rebuilds cache)
.\scripts\Repair-IconCache.ps1 -Force

# Check the log
Get-Content .\logs\IconCacheRepair.log
```

You will briefly see Explorer disappear and restart. Icons will reload. This is expected and takes 3–5 seconds.

---

## Configuration Reference

All configurable parameters are at the top of each script:

### Repair-IconCache.ps1

| Parameter | Default | Description |
|---|---|---|
| `-SizeLimitMB` | `256` | Repair if cache exceeds this size |
| `-Force` | `$false` | Skip health check, always repair |

### Watch-IconCache.ps1

| Parameter | Default | Description |
|---|---|---|
| `-SizeLimitMB` | `256` | Watchdog repair threshold in MB |
| `-CooldownMin` | `30` | Minimum minutes between repairs |
| `-RepairScript` | auto-detected | Path to `Repair-IconCache.ps1` |

### Changing the threshold

To change the size limit to 128 MB, edit the default value in `Watch-IconCache.ps1`:

```powershell
param(
    [int]$SizeLimitMB = 128,   # ← Change this
    ...
)
```

Then re-run `Register-Tasks.ps1` to update the registered task.

---

## Verifying the Watchdog Is Alive

The watchdog writes a heartbeat every 6 hours:

```powershell
Get-Content .\logs\Watchdog.log -Tail 20
```

Look for lines containing `[HEARTBEAT]`. If the last heartbeat is older than 12 hours, the watchdog may have stopped — re-run the installer to restart it.

---

## Checking Repair History

```powershell
# Full log
Get-Content .\logs\IconCacheRepair.log

# Only repairs (filter out "no action" lines)
Get-Content .\logs\IconCacheRepair.log | Where-Object { $_ -match "REPAIR|TRIGGER|ERROR" }
```

---

## Deploying on a New Machine (Reuse Checklist)

- [ ] Copy `icon-cache-self-healing\` folder to `C:\Tools\`
- [ ] Open PowerShell as Administrator
- [ ] `cd C:\Tools\icon-cache-self-healing`
- [ ] `.\scripts\Register-Tasks.ps1`
- [ ] `Get-ScheduledTask -TaskPath "\IconCache\"` — verify both tasks show `Ready` or `Running`
- [ ] `.\scripts\Repair-IconCache.ps1 -Force` — smoke test
- [ ] Done

---

## Troubleshooting

### "Access denied" when running installer
Make sure PowerShell is running **as Administrator** (right-click → Run as Administrator).

### Task shows "Disabled" state
```powershell
Enable-ScheduledTask -TaskPath "\IconCache\" -TaskName "EventRepair"
Enable-ScheduledTask -TaskPath "\IconCache\" -TaskName "Watchdog"
```

### Icons still not rebuilding after a crash
Check if the lock file is stuck:
```powershell
$lockPath = Join-Path $PSScriptRoot "..\scripts\repair.lock"
if (Test-Path $lockPath) { Remove-Item $lockPath -Force; Write-Host "Lock cleared." }
```

### Watchdog log is empty
The watchdog hasn't written a heartbeat yet (it writes every 6 hours). Either wait, or check if the `Watchdog` task is in `Running` state.

### ExecutionPolicy error
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
```

---

## Uninstall

```powershell
# Remove scheduled tasks
Unregister-ScheduledTask -TaskPath "\IconCache\" -TaskName "EventRepair" -Confirm:$false
Unregister-ScheduledTask -TaskPath "\IconCache\" -TaskName "Watchdog"    -Confirm:$false

# Remove the task folder from Task Scheduler
$svc = New-Object -ComObject Schedule.Service
$svc.Connect()
$svc.GetFolder("\").DeleteFolder("IconCache", 0)

# Delete the toolkit folder (optional)
# Remove-Item "C:\Tools\icon-cache-self-healing" -Recurse -Force
```
