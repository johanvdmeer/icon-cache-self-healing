#Requires -Version 5.1
<#
.SYNOPSIS
    One-click installer for icon-cache-self-healing v2.0.0
    Installs the compiled Go daemon as the silent background watchdog.
    Also registers Solution A (Event-triggered repair via Task Scheduler).

.DESCRIPTION
    v2.0.0 replaces the PowerShell watchdog scripts with a compiled Go binary
    (icon-cache-watchdog.exe) that runs as a true GUI-subsystem process.
    No console window. No flash. Ever.

    WHAT THIS INSTALLS:
      Task: \IconCache\EventRepair
        Trigger: explorer.exe crash (1000), hang (1002), sleep resume (107)
        Action:  Run Repair-IconCache.ps1 silently

      Task: \IconCache\Watchdog
        Trigger: At logon (runs indefinitely)
        Action:  icon-cache-watchdog.exe (GUI binary - no window)
                 Handles Layer B (file size), C (logon check), D (periodic)

.NOTES
    Naming Policy: naming-conventions-policy-v3.2.0 - Style C (Verb-Noun.ps1)
    Must run as:   Administrator
    Requires:      bin\icon-cache-watchdog.exe (run Build-Daemon.ps1 first)
    Idempotent:    Yes - safe to re-run at any time
#>

[CmdletBinding()]
param()

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
$Version      = "2.0.0"
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir      = Split-Path -Parent $ScriptDir
$LogDir       = Join-Path $RootDir "logs"
$RepairScript = Join-Path $ScriptDir "Repair-IconCache.ps1"
$DaemonExe    = Join-Path $RootDir "bin\icon-cache-watchdog.exe"
$TaskFolder   = "\IconCache"
$TaskFolderPS = "\IconCache\"

$pwsh7 = Join-Path $env:ProgramFiles "PowerShell\7\pwsh.exe"
$pwshExe = if (Test-Path $pwsh7) { $pwsh7 } else { "powershell.exe" }

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
    $current = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Step "Must be run as Administrator." 'ERROR'
        exit 1
    }
}

function Remove-ExistingTask {
    param([string]$Name)
    $t = Get-ScheduledTask -TaskPath $TaskFolderPS -TaskName $Name -ErrorAction SilentlyContinue
    if ($t) {
        Unregister-ScheduledTask -TaskPath $TaskFolderPS -TaskName $Name -Confirm:$false
        Write-Step "Removed existing task: $Name" 'WARN'
    }
}

# ---------------------------------------------------------------------------
# VALIDATE
# ---------------------------------------------------------------------------
Assert-Admin

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  icon-cache-self-healing - Installer v$Version" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $RepairScript)) {
    Write-Step "Repair script not found: $RepairScript" 'ERROR'
    exit 1
}

if (-not (Test-Path $DaemonExe)) {
    Write-Step "Daemon binary not found: $DaemonExe" 'ERROR'
    Write-Step "Run .\scripts\Build-Daemon.ps1 first to compile the binary." 'ERROR'
    exit 1
}

Write-Step "All required files found." 'OK'

if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}
Write-Step "Log directory ready: $LogDir" 'OK'

# ---------------------------------------------------------------------------
# SOLUTION A - Event-Triggered Repair (Task Scheduler)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- Registering Solution A: Event-Triggered Repair ---" -ForegroundColor White

Remove-ExistingTask "EventRepair"

$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>icon-cache-self-healing v$Version - Repairs icon cache after explorer.exe crash or hang.</Description>
    <URI>\IconCache\EventRepair</URI>
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
  </Settings>
  <Actions>
    <Exec>
      <Command>$pwshExe</Command>
      <Arguments>-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File "$RepairScript"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$tempXml = Join-Path $env:TEMP "icon-cache-event-repair.xml"
$taskXml | Out-File -FilePath $tempXml -Encoding Unicode
schtasks.exe /Create /XML $tempXml /TN "$TaskFolder\EventRepair" /F 2>&1 | Out-Null
Remove-Item $tempXml -Force -ErrorAction SilentlyContinue
Write-Step "Task registered: $TaskFolder\EventRepair" 'OK'

# ---------------------------------------------------------------------------
# SOLUTION B+C+D - Go Daemon (GUI binary, no window ever)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- Registering Watchdog Daemon (Go binary) ---" -ForegroundColor White

Remove-ExistingTask "Watchdog"

$watchXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>icon-cache-self-healing v$Version - Silent Go daemon. Handles Layer B (file size watchdog), Layer C (logon health check), Layer D (periodic health check every 45 min). GUI subsystem binary - no console window.</Description>
    <URI>\IconCache\Watchdog</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
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
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <RestartOnFailure>
      <Interval>PT5M</Interval>
      <Count>3</Count>
    </RestartOnFailure>
    <Priority>7</Priority>
  </Settings>
  <Actions>
    <Exec>
      <Command>$DaemonExe</Command>
    </Exec>
  </Actions>
</Task>
"@

$tempXml = Join-Path $env:TEMP "icon-cache-watchdog.xml"
$watchXml | Out-File -FilePath $tempXml -Encoding Unicode
schtasks.exe /Create /XML $tempXml /TN "$TaskFolder\Watchdog" /F 2>&1 | Out-Null
Remove-Item $tempXml -Force -ErrorAction SilentlyContinue
Write-Step "Task registered: $TaskFolder\Watchdog (GUI daemon - no window)" 'OK'

try {
    Start-ScheduledTask -TaskPath $TaskFolderPS -TaskName "Watchdog"
    Write-Step "Watchdog started immediately." 'OK'
} catch {
    Write-Step "Watchdog will start at next logon." 'WARN'
}

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=================================================" -ForegroundColor Green
Write-Host "  Installation Complete" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green
Write-Host ""

$tasks = Get-ScheduledTask -TaskPath $TaskFolderPS -ErrorAction SilentlyContinue
if ($tasks) {
    Write-Host "Registered tasks:" -ForegroundColor White
    $tasks | ForEach-Object {
        $stateColor = if ($_.State -in 'Ready','Running') { 'Green' } else { 'Yellow' }
        Write-Host "  $($_.TaskName.PadRight(20)) State: $($_.State)" -ForegroundColor $stateColor
    }
}

Write-Host ""
Write-Host "Log files: $LogDir" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  Smoke test:   .\scripts\Repair-IconCache.ps1 -Force" -ForegroundColor Gray
Write-Host "  Repair log:   Get-Content .\logs\IconCacheRepair.log" -ForegroundColor Gray
Write-Host "  Watchdog log: Get-Content .\logs\Watchdog.log -Tail 20" -ForegroundColor Gray
Write-Host "  Health log:   Get-Content .\logs\IconCacheHealth.log -Tail 20" -ForegroundColor Gray
Write-Host ""
