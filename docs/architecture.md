# architecture.md

**Version:** 2.0.0  
**Naming Policy:** `naming-conventions-policy-v3.2.0`

---

## Overview

The icon-cache-self-healing toolkit is a four-layer autonomous repair system for the Windows icon cache. Each layer targets a distinct failure mode. Together they cover every realistic corruption scenario without user intervention.

The production runtime is a compiled Go binary (`icon-cache-watchdog.exe`) that runs as a Windows GUI-subsystem process — completely silent, no console window, no visible footprint.

---

## Why the Cache Breaks

Windows maintains icon database files at:

```
%LOCALAPPDATA%\Microsoft\Windows\Explorer\iconcache_*.db
```

Corruption occurs in two distinct patterns:

**Pattern 1 — Size growth.** Normal Explorer usage gradually grows `iconcache_256.db`. Beyond a threshold, rendering slows and icons go blank.

**Pattern 2 — Silent external write.** Package managers (`winget`), Windows Update, and cleanup tools write to or invalidate cache files while Explorer is not running. The files do not grow — they become internally inconsistent. Size-based monitoring cannot detect this.

Windows has no native repair mechanism for either pattern.

---

## Layer Architecture

### Layer A — Event-Triggered Repair (Task Scheduler)

**Mechanism:** Windows Event Log subscription  
**Registered by:** `Register-Tasks.ps1` as `\IconCache\EventRepair`  
**Triggers:**

| Event ID | Provider | Meaning |
|---|---|---|
| 1000 | Application Error | `explorer.exe` hard crash |
| 1002 | Application Hang | `explorer.exe` stopped responding |
| 107 | Kernel-Power | System resumed from sleep |

**Action:** Launches `Repair-IconCache.ps1` with a 60–90 second delay to allow Explorer to attempt its own recovery first.

**Coverage:** Reactive. Catches crashes and hangs. Sleep resume provides an opportunistic check after the system wakes.

---

### Layer B — Size Watchdog (Go Daemon)

**Mechanism:** 30-second polling loop inside `icon-cache-watchdog.exe`  
**Threshold:** 32 MB total `iconcache_*.db` size  
**Cooldown:** 30 minutes between consecutive repairs

**Coverage:** Reactive. Catches gradual size growth before it causes visible symptoms. The 30-second poll is far more responsive than the previous FileSystemWatcher implementation and requires zero external dependencies.

---

### Layer C — Startup Health Check (Go Daemon)

**Mechanism:** Heuristic evaluation at process startup  
**Runs:** Once at every logon, immediately after the daemon starts

**Coverage:** Proactive. Catches corruption that survived the previous session — external writes that occurred after the last health check, index damage from abnormal shutdowns.

---

### Layer D — Periodic Health Check (Go Daemon)

**Mechanism:** Heuristic evaluation on a 45-minute timer  
**Runs:** Every 45 minutes throughout the session, indefinitely

**Coverage:** Proactive. Closes the mid-session gap. Catches `winget` updates, Windows Update side effects, and manual cleanup operations that corrupt the cache during the working day without triggering a crash.

---

## Health Check Heuristics

Layers C and D evaluate four heuristics. Any failure triggers an immediate repair.

**H1 — Index integrity**  
`iconcache_idx.db` is the master index for all cache entries. If it is missing or smaller than 100 bytes, the entire cache is broken regardless of other file states.

**H2 — External write detection**  
If `iconcache_256.db` was modified in the last 15 minutes while `explorer.exe` was not running, an external process (package manager, update service, cleanup tool) wrote to the cache. This is the primary heuristic for catching `winget` and Windows Update corruption.

**H3 — File count sanity**  
A healthy cache maintained by a running Explorer process contains 10–15 database files. If Explorer is running but fewer than 5 files exist, an abnormal deletion has occurred.

**H4 — Staleness**  
If no cache file has been modified in 30 or more days, a preemptive rebuild is triggered. Stale caches accumulate orphaned entries that degrade rendering performance over time.

---

## Why a Go Binary Instead of PowerShell

The PowerShell scripts (`Watch-IconCache.ps1`, `Test-IconCacheHealth.ps1`) are retained in the repository as **reference implementations** — readable, auditable documentation of the system's logic in a language accessible to any Windows administrator.

The production runtime is `icon-cache-watchdog.exe` for one fundamental reason:

`powershell.exe` and `pwsh.exe` are **console-subsystem** executables (`IMAGE_SUBSYSTEM_WINDOWS_CUI`). When Task Scheduler launches a console-subsystem process, Windows unconditionally allocates a `conhost.exe` console host before the process starts. The `-WindowStyle Hidden` flag and all XML `<Hidden>` settings operate on the window after it is created — they cannot prevent its initial allocation. The result is a visible terminal flash at every logon and every triggered repair.

The Go binary is compiled with:

```
go build -ldflags="-H windowsgui"
```

This sets `IMAGE_SUBSYSTEM_WINDOWS_GUI` in the PE header. Windows never allocates a console host for GUI-subsystem processes. Additionally, all child processes spawned by the daemon (repair script invocations) are created with the `CREATE_NO_WINDOW` flag (`0x08000000`) via `syscall_windows.go`, ensuring the entire call chain is silent.

---

## Repair Process

When any layer triggers a repair, `Repair-IconCache.ps1` executes the following sequence:

```
1. Stop explorer.exe gracefully
2. Wait for process termination (max 5 seconds)
3. Delete all iconcache_*.db files
4. Execute ie4uinit.exe -show (resets the shell icon index)
5. Restart explorer.exe
6. Log result to logs/IconCacheRepair.log
```

Total elapsed time: 3–5 seconds. Explorer briefly disappears and returns with a clean cache.

---

## Naming Policy

All files in this repository comply with `naming-conventions-policy-v3.2.0`:

| File Type | Style | Rule |
|---|---|---|
| PowerShell `.ps1` | C | `Verb-Noun.ps1` |
| Markdown `.md` | B | `kebab-case.md` |
| XML config | B | `kebab-case.xml` |
| Go source | B | `snake_case.go` |
| Directories | B | `kebab-case/` |
| Repository root | B | `kebab-case/` |

---

## Event ID Reference

| ID | Log | Provider | Used by |
|---|---|---|---|
| 1000 | Application | Application Error | Layer A |
| 1002 | Application | Application Hang | Layer A |
| 107 | System | Microsoft-Windows-Kernel-Power | Layer A |
