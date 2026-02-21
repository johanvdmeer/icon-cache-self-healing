#Requires -Version 5.1
<#
.SYNOPSIS
    One-click installer for icon-cache-self-healing v1.2.0
    Registers all four layers of the self-healing system.

.NOTES
    Naming Policy: naming-conventions-policy-v3.2.0 - Style C (Verb-Noun.ps1)
    Must run as:   Administrator
    Idempotent:    Yes - safe to re-run at any time
#>

[CmdletBinding()]
param()

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
$Version      = "1.2.0"
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir      = Split-Path -Parent $ScriptDir
$LogDir       = Join-Path $RootDir "logs"
$RepairScript = Join-Path $ScriptDir "Repair-IconCache.ps1"
$WatchScript  = Join-Path $ScriptDir "Watch-IconCache.ps1"
$HealthScript = Join-Path $ScriptDir "Test-IconCacheHealth.ps1"
$TaskFolder   = "\IconCache"          # NO trailing slash - COM object requires this
$TaskFolderPS = "\IconCache\"         # WITH trailing slash - PowerShell cmdlets require this

# ---------------------------------------------------------------------------
# DETECT POWERSHELL 7
# Pwsh.exe is a console app and will always flash a window.
# We use pwsh.exe for the HealthCheck (short-lived, acceptable).
# For the Watchdog (long-running daemon) we use a different strategy.
# ---------------------------------------------------------------------------
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

function Ensure-TaskFolder {
    try {
        $svc = New-Object -ComObject Schedule.Service
        $svc.Connect()
        try { $svc.GetFolder($TaskFolder) | Out-Null }
        catch { $svc.GetFolder("\").CreateFolder("IconCache") | Out-Null }
    } catch { }
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

foreach ($s in @($RepairScript, $WatchScript, $HealthScript)) {
    if (-not (Test-Path $s)) {
        Write-Step "Required script not found: $s" 'ERROR'
        exit 1
    }
}
Write-Step "All required scripts found." 'OK'

if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}
Write-Step "Log directory ready: $LogDir" 'OK'

Ensure-TaskFolder

# ---------------------------------------------------------------------------
# SOLUTION A - Event-Triggered Repair
# Fires on: explorer.exe crash (1000), hang (1002), resume from sleep (107)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- Registering Solution A: Event-Triggered Repair ---" -ForegroundColor White

Remove-ExistingTask "EventRepair"

$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>icon-cache-self-healing v$Version - Solution A. Repairs icon cache after explorer.exe crash (1000) or hang (1002). Opportunistic check after sleep resume (107).</Description>
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
Write-Step "Task registered: $TaskFolder\EventRepair  (Event ID 1000/1002/107)" 'OK'

# ---------------------------------------------------------------------------
# SOLUTION B - Watchdog Daemon
# Long-running process. Uses XML registration with Hidden=true at OS level.
# This is the only reliable way to suppress the console window for a daemon.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- Registering Solution B: File-Size Watchdog Daemon ---" -ForegroundColor White

Remove-ExistingTask "Watchdog"

$watchXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>icon-cache-self-healing v$Version - Solution B. FileSystemWatcher daemon. Repairs when cache exceeds size threshold.</Description>
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
      <Command>$pwshExe</Command>
      <Arguments>-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File "$WatchScript"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$tempXml = Join-Path $env:TEMP "icon-cache-watchdog.xml"
$watchXml | Out-File -FilePath $tempXml -Encoding Unicode
schtasks.exe /Create /XML $tempXml /TN "$TaskFolder\Watchdog" /F 2>&1 | Out-Null
Remove-Item $tempXml -Force -ErrorAction SilentlyContinue
Write-Step "Task registered: $TaskFolder\Watchdog  (FileSystemWatcher daemon, at logon)" 'OK'

try {
    Start-ScheduledTask -TaskPath $TaskFolderPS -TaskName "Watchdog"
    Write-Step "Watchdog started immediately." 'OK'
} catch {
    Write-Step "Watchdog will start at next logon." 'WARN'
}

# ---------------------------------------------------------------------------
# SOLUTION C+D - Proactive Health Check
# Runs at logon AND every 45 minutes via XML repetition interval.
# Short-lived script - window flash acceptable here (completes in <5 seconds).
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- Registering Solution C+D: Proactive Health Check ---" -ForegroundColor White

Remove-ExistingTask "HealthCheck"

$healthXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>icon-cache-self-healing v$Version - Solution C+D. Proactive health checker. Runs at logon and every 45 minutes. Detects silent corruption via heuristics.</Description>
    <URI>\IconCache\HealthCheck</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <Repetition>
        <Interval>PT45M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
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
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions>
    <Exec>
      <Command>$pwshExe</Command>
      <Arguments>-WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File "$HealthScript"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$tempXml = Join-Path $env:TEMP "icon-cache-healthcheck.xml"
$healthXml | Out-File -FilePath $tempXml -Encoding Unicode
schtasks.exe /Create /XML $tempXml /TN "$TaskFolder\HealthCheck" /F 2>&1 | Out-Null
Remove-Item $tempXml -Force -ErrorAction SilentlyContinue
Write-Step "Task registered: $TaskFolder\HealthCheck  (logon + every 45 min)" 'OK'

try {
    Start-ScheduledTask -TaskPath $TaskFolderPS -TaskName "HealthCheck"
    Write-Step "HealthCheck started immediately." 'OK'
} catch {
    Write-Step "HealthCheck will run at next logon." 'WARN'
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
