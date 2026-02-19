# icon-cache-self-healing

**Version:** 1.0.0  
**Target OS:** Windows 11 (compatible with Windows 10 21H2+)  
**Naming Policy:** Compliant with `naming-conventions-policy-v3.2.0`  
**Principle:** Event-Driven, not Time-Based. The system heals itself — you don't need to think about it.

---

## What This Does

Windows silently accumulates `iconcache_*.db` files inside `%LOCALAPPDATA%\Microsoft\Windows\Explorer`. When these files grow too large or become corrupted, you get missing icons, blank thumbnails, or Explorer crashes. Windows provides no native self-repair mechanism for this.

This toolkit installs a **two-layer watchdog system**:

| Layer | Mechanism | Trigger |
|---|---|---|
| **Solution A** | Task Scheduler (Event-Driven) | Explorer crash → Event ID 1000 / 1002 |
| **Solution B** | PowerShell Daemon (FileSystemWatcher) | File size exceeds threshold (default: 256 MB) |

Both layers are **silent, autonomous, and low-resource**. No popups. No scheduled reboots. No manual intervention.

---

## Folder Structure

```
icon-cache-self-healing/
├── readme.md                        ← You are here
├── docs/
│   ├── architecture.md              ← System design, event ID analysis, flow diagrams
│   └── implementation-guide.md      ← Step-by-step setup on a new machine
├── scripts/
│   ├── Repair-IconCache.ps1         ← Core repair logic (run standalone or triggered)
│   ├── Watch-IconCache.ps1          ← Watchdog daemon (FileSystemWatcher-based)
│   └── Register-Tasks.ps1          ← One-click installer for both solutions
├── tasks/
│   └── icon-cache-event-repair.xml  ← Task Scheduler XML (Event ID 1000/1002 triggers)
└── logs/                            ← Auto-created at runtime (gitignored)
```

---

## Quick Start (New Machine)

```powershell
# 1. Open PowerShell as Administrator
# 2. Navigate to this folder
cd "C:\path\to\icon-cache-self-healing"

# 3. Run the one-click installer
.\scripts\Register-Tasks.ps1

# 4. Verify installation
Get-ScheduledTask -TaskPath "\IconCache\" | Select-Object TaskName, State
```

That's it. Both solutions are now active.

---

## Naming Conventions Compliance

This project strictly follows `naming-conventions-policy-v3.2.0`:

| File Type | Rule Applied | Example |
|---|---|---|
| PowerShell `.ps1` | Style C: `Verb-Noun` | `Repair-IconCache.ps1` |
| Markdown `.md` | Style B: `kebab-case` | `implementation-guide.md` |
| XML config | Style B: `kebab-case` | `icon-cache-event-repair.xml` |
| Directories | Style B: `kebab-case` | `scripts/`, `docs/`, `tasks/` |
| Repository root | Style B: `kebab-case` | `icon-cache-self-healing/` |

---

## Requirements

- Windows 10 21H2 or Windows 11 (any version)
- PowerShell 5.1+ (built-in on all modern Windows)
- Administrator rights (required for Task Scheduler registration only)
- No third-party dependencies

---

## Uninstall

```powershell
# Remove both scheduled tasks
Unregister-ScheduledTask -TaskPath "\IconCache\" -TaskName "EventRepair" -Confirm:$false
Unregister-ScheduledTask -TaskPath "\IconCache\" -TaskName "Watchdog"    -Confirm:$false

# Remove task folder
$scheduler = New-Object -ComObject Schedule.Service
$scheduler.Connect()
$scheduler.GetFolder("\").DeleteFolder("IconCache", 0)
```
