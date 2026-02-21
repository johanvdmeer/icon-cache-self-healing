#Requires -Version 5.1
<#
.SYNOPSIS
    Compiles icon-cache-watchdog.exe from Go source.
    Output: bin\icon-cache-watchdog.exe (GUI subsystem, no console window)

.NOTES
    Naming Policy: naming-conventions-policy-v3.2.0 - Style C (Verb-Noun.ps1)
    Requires:      Go 1.20+ installed (https://go.dev/dl/)
    Output:        bin\icon-cache-watchdog.exe
#>

[CmdletBinding()]
param()

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir    = Split-Path -Parent $ScriptDir
$DaemonDir  = Join-Path $RootDir "daemon"
$BinDir     = Join-Path $RootDir "bin"
$OutputExe  = Join-Path $BinDir "icon-cache-watchdog.exe"

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

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  Build-Daemon.ps1 - icon-cache-watchdog.exe" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

# Check Go is installed
try {
    $goVersion = & go version 2>&1
    Write-Step "Go found: $goVersion" 'OK'
} catch {
    Write-Step "Go is not installed or not in PATH." 'ERROR'
    Write-Step "Download from: https://go.dev/dl/" 'ERROR'
    Write-Step "Install Go, then re-run this script." 'ERROR'
    exit 1
}

# Create bin\ directory
if (-not (Test-Path $BinDir)) {
    New-Item -Path $BinDir -ItemType Directory -Force | Out-Null
}

# Compile
Write-Step "Compiling for Windows x64 (GUI subsystem)..." 'INFO'
Write-Step "Source: $DaemonDir" 'INFO'
Write-Step "Output: $OutputExe" 'INFO'
Write-Host ""

$env:GOOS   = "windows"
$env:GOARCH = "amd64"
$env:CGO_ENABLED = "0"

Push-Location $DaemonDir
try {
    & go build -ldflags="-H windowsgui -s -w" -o $OutputExe .
    if ($LASTEXITCODE -ne 0) {
        Write-Step "Compilation failed." 'ERROR'
        exit 1
    }
} finally {
    Pop-Location
    $env:GOOS = $null
    $env:GOARCH = $null
    $env:CGO_ENABLED = $null
}

$size = [math]::Round((Get-Item $OutputExe).Length / 1MB, 1)
Write-Host ""
Write-Step "Build successful: icon-cache-watchdog.exe ($size MB)" 'OK'
Write-Step "Binary type: PE32+ GUI subsystem (no console window, ever)" 'OK'
Write-Host ""
Write-Host "Next step: run .\scripts\Register-Tasks.ps1 as Administrator" -ForegroundColor Gray
Write-Host ""
