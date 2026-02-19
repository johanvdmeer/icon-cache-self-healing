#Requires -Version 5.1
<#
.SYNOPSIS
    One-click installer for the icon-cache-self-healing toolkit.
    Registers both Solution A (Event-triggered repair) and Solution B
    (File-size watchdog daemon) in Windows Task Scheduler.

.DESCRIPTION
    Run this script once on any new Windows machine to activate the full
    icon cache self-healing system. Requires Administrator privileges
    (for Task Scheduler registration only — the repair scripts themselves
    run in user context).

    WHAT THIS INSTALLS:
      Task: \IconCache\EventRepair
        Trigger: Event ID 1000 (explorer.exe crash) or 1002 (explorer.exe hang)
        Also:    Event ID 107 (resume from sleep, opportunistic check)
        Action:  Run Repair-IconCache.ps1 (silently, hidden window)

      Task: \IconCache\Watchdog
        Trigger: At logon (runs indefinitely)
        Action:  Run Watch-IconCache.ps1 (FileSystemWatcher daemon)

.NOTES
    Naming Policy:  naming-conventions-policy-v3.2.0 — Style C (Verb-Noun.ps1)
    Must be run:    As Administrator
    Idempotent:     Yes — safe to re-run. Existing tasks are deleted and recreated.

.EXAMPLE
    # Run as Administrator from the project root:
    .\scripts\Register-Tasks.ps1

.EXAMPLE
    # If you moved the folder, re-run to update the hardcoded paths:
    .\scripts\Register-Tasks.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# CONFIGURATION — paths are derived from this script's location
# ---------------------------------------------------------------------------
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir      = Split-Path -Parent $ScriptDir
$LogDir       = Join-Path $RootDir "logs"
$RepairScript = Join-Path $ScriptDir "Repair-IconCache.ps1"
$WatchScript  = Join-Path $ScriptDir "Watch-IconCache.ps1"
$TaskFolder   = "\IconCache\"
$Version      = "1.0.0"

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------
function Write-Step {
    param([string]$Message, [string]$Status = 'INFO')
    $color = switch ($Status) {
        'OK'    { 'Green'  }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red'    }
        default { 'Cyan'   }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $color
}

function Assert-Admin {
    $currentUser = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Step "This script must be run as Administrator." 'ERROR'
        Write-Step "Right-click PowerShell and select 'Run as Administrator', then try again." 'ERROR'
        exit 1
    }
}

function Remove-ExistingTask {
    param([string]$TaskName)
    $existing = Get-ScheduledTask -TaskPath $TaskFolder -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskPath $TaskFolder -TaskName $TaskName -Confirm:$false
        Write-Step "Removed existing task: $TaskName" 'WARN'
    }
}

function Ensure-TaskFolder {
    # Task Scheduler folder is created implicitly by Register-ScheduledTask
    # but we attempt an explicit check for robustness
    try {
        $svc = New-Object -ComObject Schedule.Service
        $svc.Connect()
        $root = $svc.GetFolder("\")
        try {
            $root.GetFolder("IconCache") | Out-Null
        } catch {
            $root.CreateFolder("IconCache") | Out-Null
            Write-Step "Created Task Scheduler folder: \IconCache\" 'OK'
        }
    } catch {
        # Non-fatal — Register-ScheduledTask will create it anyway
    }
}

# ---------------------------------------------------------------------------
# VALIDATION
# ---------------------------------------------------------------------------
Assert-Admin

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  icon-cache-self-healing — Installer v$Version" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

# Verify scripts exist
foreach ($script in @($RepairScript, $WatchScript)) {
    if (-not (Test-Path $script)) {
        Write-Step "Required script not found: $script" 'ERROR'
        Write-Step "Make sure you are running this from inside the 'scripts' folder of the toolkit." 'ERROR'
        exit 1
    }
}
Write-Step "All required scripts found." 'OK'

# Ensure log directory exists
if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}
Write-Step "Log directory ready: $LogDir" 'OK'

Ensure-TaskFolder

# ---------------------------------------------------------------------------
# SOLUTION A — Event-Triggered Repair Task
# Fires when: explorer.exe crashes (1000), hangs (1002), or after sleep (107)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- Registering Solution A: Event-Triggered Repair ---" -ForegroundColor White

Remove-ExistingTask -TaskName "EventRepair"

# XPath query: Event 1000 where faulting app is explorer.exe
$query1000 = @"
<QueryList>
  <Query Id="0" Path="Application">
    <Select Path="Application">
      *[System[Provider[@Name='Application Error'] and EventID=1000]]
      and
      *[EventData[Data[@Name='param1'] and (Data='explorer.exe')]]
    </Select>
  </Query>
</QueryList>
"@

# XPath query: Event 1002 where hanging app is explorer.exe
$query1002 = @"
<QueryList>
  <Query Id="0" Path="Application">
    <Select Path="Application">
      *[System[Provider[@Name='Application Hang'] and EventID=1002]]
      and
      *[EventData[Data[@Name='param1'] and (Data='explorer.exe')]]
    </Select>
  </Query>
</QueryList>
"@

# XPath query: Event 107 (resume from sleep)
$query107 = @"
<QueryList>
  <Query Id="0" Path="System">
    <Select Path="System">
      *[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=107]]
    </Select>
  </Query>
</QueryList>
"@

$triggerA1 = New-ScheduledTaskTrigger -AtStartup    # Placeholder — replaced by XML below
# Note: Event triggers require the CIM/XML approach; PowerShell cmdlets don't expose them natively

# Build the full task via XML for precise event trigger support
$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>icon-cache-self-healing v$Version — Solution A. Repairs icon cache after explorer.exe crash or hang (Event ID 1000/1002). Also runs an opportunistic check after resume from sleep (Event ID 107).</Description>
    <URI>{0}EventRepair</URI>
  </RegistrationInfo>
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription><![CDATA[<QueryList><Query Id="0" Path="Application"><Select Path="Application">*[System[Provider[@Name='Application Error'] and EventID=1000]] and *[EventData[Data[@Name='param1'] and (Data='explorer.exe')]]</Select></Query></QueryList>]]></Subscription>
      <Delay>PT60S</Delay>
    </EventTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription><![CDATA[<QueryList><Query Id="0" Path="Application"><Select Path="Application">*[System[Provider[@Name='Application Hang'] and EventID=1002]] and *[EventData[Data[@Name='param1'] and (Data='explorer.exe')]]</Select></Query></QueryList>]]></Subscription>
      <Delay>PT90S</Delay>
    </EventTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription><![CDATA[<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=107]]</Select></Query></QueryList>]]></Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <Hidden>true</Hidden>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT2M</Interval>
      <Count>2</Count>
    </RestartOnFailure>
  </Settings>
  <Actions>
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File "{1}"</Arguments>
    </Exec>
  </Actions>
</Task>
"@ -f $TaskFolder, $RepairScript

$tempXml = Join-Path $env:TEMP "icon-cache-event-repair-temp.xml"
$taskXml | Out-File -FilePath $tempXml -Encoding Unicode
schtasks.exe /Create /XML $tempXml /TN "$($TaskFolder)EventRepair" /F 2>&1 | Out-Null
Remove-Item $tempXml -Force -ErrorAction SilentlyContinue

Write-Step "Task registered: ${TaskFolder}EventRepair  (Event ID 1000 / 1002 / 107)" 'OK'

# ---------------------------------------------------------------------------
# SOLUTION B — Watchdog Daemon Task
# Starts at logon, runs indefinitely, uses FileSystemWatcher (interrupt-based)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- Registering Solution B: File-Size Watchdog Daemon ---" -ForegroundColor White

Remove-ExistingTask -TaskName "Watchdog"

$actionB = New-ScheduledTaskAction `
    -Execute  'powershell.exe' `
    -Argument "-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$WatchScript`""

$triggerB = New-ScheduledTaskTrigger -AtLogOn

$settingsB = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit      ([TimeSpan]::Zero) `
    -RestartCount            3 `
    -RestartInterval         (New-TimeSpan -Minutes 5) `
    -MultipleInstances       IgnoreNew `
    -Hidden                  `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries

Register-ScheduledTask `
    -TaskPath   $TaskFolder `
    -TaskName   "Watchdog" `
    -Action     $actionB `
    -Trigger    $triggerB `
    -Settings   $settingsB `
    -RunLevel   Limited `
    -Description "icon-cache-self-healing v$Version — Solution B. Low-resource icon cache watchdog. Uses FileSystemWatcher (ReadDirectoryChangesW) — not polling. Repairs when cache exceeds size threshold." `
    | Out-Null

Write-Step "Task registered: ${TaskFolder}Watchdog  (FileSystemWatcher daemon, at logon)" 'OK'

# ---------------------------------------------------------------------------
# START WATCHDOG NOW (don't wait for next logon)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- Starting Watchdog daemon immediately ---" -ForegroundColor White
try {
    Start-ScheduledTask -TaskPath $TaskFolder -TaskName "Watchdog"
    Write-Step "Watchdog started successfully (no reboot required)." 'OK'
} catch {
    Write-Step "Could not start Watchdog immediately. It will start at next logon. Error: $_" 'WARN'
}

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=================================================" -ForegroundColor Green
Write-Host "  Installation Complete" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green
Write-Host ""

$tasks = Get-ScheduledTask -TaskPath $TaskFolder -ErrorAction SilentlyContinue
if ($tasks) {
    Write-Host "Registered tasks:" -ForegroundColor White
    $tasks | ForEach-Object {
        $stateColor = if ($_.State -in 'Ready','Running') { 'Green' } else { 'Yellow' }
        Write-Host "  $($_.TaskName.PadRight(20)) State: $($_.State)" -ForegroundColor $stateColor
    }
}

Write-Host ""
Write-Host "Log files will appear in: $LogDir" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  Smoke test:   .\scripts\Repair-IconCache.ps1 -Force" -ForegroundColor Gray
Write-Host "  Check logs:   Get-Content .\logs\IconCacheRepair.log" -ForegroundColor Gray
Write-Host "  Watch logs:   Get-Content .\logs\Watchdog.log -Tail 20" -ForegroundColor Gray
Write-Host ""
