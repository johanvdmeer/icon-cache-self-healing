# Architecture — icon-cache-self-healing

**Version:** 1.0.0  
**Last Updated:** 2025-11-20

---

## 1. Problem Statement

Windows 11 manages icon and thumbnail metadata in binary database files stored at:

```
%LOCALAPPDATA%\Microsoft\Windows\Explorer\
  iconcache_16.db
  iconcache_32.db
  iconcache_48.db
  iconcache_96.db
  iconcache_256.db
  iconcache_1280.db
  iconcache_2560.db
  iconcache_sr.db
  iconcache_wide.db
  iconcache_exif.db
  thumbcache_*.db
```

These files grow unbounded and can corrupt silently. Windows does not emit a dedicated event log entry when this happens. There is no native auto-repair mechanism.

---

## 2. Does a Native "Icon Cache Corrupt" Event ID Exist?

**Answer: No — not directly. But proxy events exist.**

| Event ID | Log Source | Description | Relevance |
|---|---|---|---|
| **1000** | `Application` → `Application Error` | `explorer.exe` hard crash | ⭐⭐⭐ Primary trigger |
| **1002** | `Application` → `Application Hang` | `explorer.exe` unresponsive | ⭐⭐⭐ Primary trigger |
| **5379** | `Microsoft-Windows-Shell-Core/Operational` | Shell property store failure | ⭐⭐ Secondary |
| **1534** | `User Profile Service` | Profile-level cache load errors | ⭐ Low-signal |
| **107** | `Microsoft-Windows-Kernel-Power` | Resume from sleep/hibernation | ⭐⭐ Supplemental (opportunistic check) |

**Conclusion:** Event ID 1000/1002 filtered to `faulting application = explorer.exe` is the best available native trigger. All other monitoring is supplemented by Solution B (file-size watchdog).

---

## 3. System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        WINDOWS 11 KERNEL                        │
│                                                                 │
│  ┌──────────────┐  crash/hang   ┌─────────────────────────┐    │
│  │ explorer.exe │ ────────────▶ │ Windows Event Log        │    │
│  └──────────────┘               │ Event ID 1000 / 1002     │    │
│                                 └────────────┬────────────┘    │
│                                              │                  │
│                                  ┌───────────▼───────────┐     │
│  ┌──────────────┐  FSW interrupt │ Task Scheduler         │     │
│  │iconcache_*.db│ ─────────────▶│ "On Event" Trigger     │     │
│  │ grows > X MB │               │ [SOLUTION A]            │     │
│  └──────────────┘               └───────────┬────────────┘     │
│         │                                   │                  │
│         │ ReadDirectoryChangesW              │                  │
│         ▼                                   ▼                  │
│  ┌──────────────┐               ┌───────────────────────┐      │
│  │Watch-Icon    │               │                       │      │
│  │Cache.ps1     │               │  Repair-IconCache.ps1 │      │
│  │[SOLUTION B]  │ ─────────────▶│  (shared core logic)  │      │
│  │ ~0% CPU idle │               │                       │      │
│  └──────────────┘               └───────────┬───────────┘      │
│                                             │                  │
│                                  ┌──────────▼──────────┐       │
│                                  │ logs/               │       │
│                                  │  IconCacheRepair.log│       │
│                                  │  Watchdog.log       │       │
│                                  └─────────────────────┘       │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. Solution A — Event-Driven Repair (Task Scheduler)

**Type:** Reactive (responds after a symptom occurs)  
**Latency:** 60–90 seconds after the triggering event  
**CPU cost:** 0% at rest — Task Scheduler wakes only on matching event

**Trigger chain:**
1. `explorer.exe` crashes or hangs.
2. Windows writes Event ID 1000 or 1002 to the Application log.
3. Task Scheduler detects the matching XPath query.
4. After a configurable delay (60s), `Repair-IconCache.ps1` runs silently.
5. Explorer restarts automatically. Icons rebuild from scratch.

**Also triggers on:**
- Event ID 107 (Kernel-Power): resume from sleep — an opportunistic check, not reactive repair.

---

## 5. Solution B — Proactive Watchdog Daemon (FileSystemWatcher)

**Type:** Proactive (prevents the symptom before a crash occurs)  
**Latency:** Milliseconds after a file-size threshold is crossed  
**CPU cost:** ~0% at idle (interrupt-driven via `ReadDirectoryChangesW` kernel API)

**Key technical detail — Polling vs. Interrupt:**

| Method | CPU at idle | Latency | Mechanism |
|---|---|---|---|
| `while ($true) { sleep 60; check }` | Low but constant | 0–60 seconds | Busy polling |
| `FileSystemWatcher` (this solution) | **~0%** | **Milliseconds** | OS kernel interrupt |

`FileSystemWatcher` wraps the Windows `ReadDirectoryChangesW` API. The OS kernel delivers a notification to the .NET event queue only when a watched file changes. The PowerShell process sleeps via `Wait-Event` (a true OS wait handle — no CPU spin) until a notification arrives.

**Cooldown logic:** A configurable cooldown (default: 30 minutes) prevents repeated repairs from firing if the cache rebuilds quickly.

**Heartbeat:** Every 6 hours, the watchdog writes a status line to `logs/Watchdog.log` confirming it is alive and reporting the current cache size. This makes it easy to verify the daemon is running without opening Task Manager.

---

## 6. Lock File Mechanism

Both solutions share a lock file at `scripts\repair.lock` to prevent simultaneous repair runs (e.g., if Solution A and Solution B both fire within seconds of each other):

1. Script checks for `repair.lock`.
2. If lock exists and is younger than 10 minutes → skip this run.
3. If lock exists and is older than 10 minutes → stale lock, proceed.
4. Script creates lock at start, removes it in `finally` block regardless of success/failure.

---

## 7. Log Files

| File | Written by | Contents |
|---|---|---|
| `logs/IconCacheRepair.log` | `Repair-IconCache.ps1` | Each repair event: files deleted, size before, outcome |
| `logs/Watchdog.log` | `Watch-IconCache.ps1` | FSW events, threshold breaches, heartbeats, errors |

Logs are append-only. They are not rotated automatically in v1.0.0 — add a scheduled log-rotation task if you plan to run this for years.
