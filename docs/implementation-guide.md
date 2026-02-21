# implementation-guide.md

**Version:** 2.0.0  
**Target OS:** Windows 10 21H2 or Windows 11 (any version)

This guide walks through setting up the icon-cache-self-healing toolkit on any machine from scratch.

---

## Prerequisites

| Requirement | Purpose | Notes |
|---|---|---|
| Windows 10 21H2+ or Windows 11 | Target platform | Any edition |
| PowerShell 5.1+ | Repair script runtime | Built into Windows |
| Go 1.20+ | Compile the daemon binary | One-time setup |
| Administrator rights | Task Scheduler registration | Install step only |

---

## Step 0 — Install Go

Go is required once to compile the daemon binary. After compilation, Go is not needed at runtime.

1. Download the Windows installer from [https://go.dev/dl/](https://go.dev/dl/)
2. Run the installer with default settings
3. Open a new PowerShell window and verify:

```powershell
go version
# Expected: go version go1.2x.x windows/amd64
```

---

## Step 1 — Clone or Download the Repository

```powershell
# Option A — Git clone
git clone https://github.com/johanvdmeer/icon-cache-self-healing.git
cd icon-cache-self-healing

# Option B — Download ZIP from GitHub, extract, then navigate to folder
cd "C:\path\to\icon-cache-self-healing"
```

---

## Step 2 — Compile the Daemon

```powershell
# Run as normal user (no Admin required for compilation)
.\scripts\Build-Daemon.ps1
```

Expected output:
```
[OK] Go found: go version go1.2x.x windows/amd64
[OK] Build successful: icon-cache-watchdog.exe (1.7 MB)
[OK] Binary type: PE32+ GUI subsystem (no console window, ever)
```

This creates `bin\icon-cache-watchdog.exe` — a Windows GUI-subsystem binary. It runs completely silently with no console window at any point.

---

## Step 3 — Register the Tasks

```powershell
# Run as Administrator
.\scripts\Register-Tasks.ps1
```

Expected output:
```
[OK] All required files found.
[OK] Log directory ready: ...\logs
[OK] Task registered: \IconCache\EventRepair
[OK] Task registered: \IconCache\Watchdog (GUI daemon - no window)
[OK] Watchdog started immediately.

Registered tasks:
  EventRepair   State: Ready
  Watchdog      State: Running
```

The Watchdog starts immediately — no reboot required.

---

## Step 4 — Verify Installation

```powershell
# Confirm both tasks are registered
Get-ScheduledTask -TaskPath "\IconCache\" | Select-Object TaskName, State

# Run a forced repair to confirm the repair pipeline works end-to-end
.\scripts\Repair-IconCache.ps1 -Force

# Check repair completed successfully
Get-Content .\logs\IconCacheRepair.log -Tail 10

# Check daemon started and health checks are passing
Get-Content .\logs\Watchdog.log -Tail 10
Get-Content .\logs\IconCacheHealth.log -Tail 10
```

A healthy `IconCacheHealth.log` looks like:

```
[INFO]  --- Health check running (startup) ---
[PASS]  H1 PASS: iconcache_idx.db present and 57 KB.
[PASS]  H2 PASS: Last modified 4 min ago (outside suspicious window).
[PASS]  H3 PASS: 15 cache files present.
[PASS]  H4 PASS: Cache last updated 0.0 days ago.
[PASS]  === ALL HEURISTICS PASSED. Cache is healthy. ===
```

---

## Step 5 — Reboot Confirmation

Reboot the machine and log in. Confirm:

- No terminal window appears at login
- `Get-ScheduledTask -TaskPath "\IconCache\" | Select-Object TaskName, State` shows `Watchdog = Running`
- `Get-Content .\logs\Watchdog.log -Tail 5` shows a fresh startup line

---

## What Runs After Installation

Once installed, the system is fully autonomous:

| What | When | Visible to user |
|---|---|---|
| `icon-cache-watchdog.exe` starts | Every logon | Nothing |
| Health check runs | At logon + every 45 min | Nothing |
| Size check runs | Every 30 seconds | Nothing |
| Repair fires if needed | On demand | Explorer restarts (3-5 sec) |
| Event repair fires | On explorer.exe crash | Explorer restarts (3-5 sec) |

The only visible behaviour is Explorer briefly disappearing and returning when a repair fires — which is the intentional, correct result.

---

## Rebuilding After Source Changes

If you modify `daemon/main.go`:

```powershell
.\scripts\Build-Daemon.ps1
.\scripts\Register-Tasks.ps1
```

The installer is idempotent — it removes and recreates the tasks cleanly every run.

---

## Uninstall

```powershell
# Remove scheduled tasks
Unregister-ScheduledTask -TaskPath "\IconCache\" -TaskName "EventRepair" -Confirm:$false
Unregister-ScheduledTask -TaskPath "\IconCache\" -TaskName "Watchdog"    -Confirm:$false

# Remove task folder from Task Scheduler
$scheduler = New-Object -ComObject Schedule.Service
$scheduler.Connect()
$scheduler.GetFolder("\").DeleteFolder("IconCache", 0)
```

Then delete the project folder. No registry modifications. No system files touched.

---

## Log File Reference

| File | Written by | Contents |
|---|---|---|
| `logs/Watchdog.log` | Go daemon | Startup, size checks, heartbeat, repair triggers |
| `logs/IconCacheHealth.log` | Go daemon | Heuristic results, pass/fail per check |
| `logs/IconCacheRepair.log` | `Repair-IconCache.ps1` | Each repair run, files deleted, before/after size |
