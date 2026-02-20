' launch-watchdog.vbs
' Silent launcher for Watch-IconCache.ps1
'
' WHY THIS EXISTS:
'   powershell.exe is a console application. Windows always allocates a console
'   window for console apps at the OS level, before -WindowStyle Hidden can act.
'   This causes a visible CLI flash on every startup.
'
'   wscript.exe is a GUI (windowed) application. Windows never allocates a console
'   for it. Using WScript.Shell.Run with style 0 (vbHide) launches PowerShell
'   with zero visible window — ever. Not even a flash.
'
' Naming Policy: naming-conventions-policy-v3.2.0 — Style B (kebab-case script)

Dim oShell, scriptDir, ps1Path

Set oShell  = CreateObject("WScript.Shell")
scriptDir   = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
ps1Path     = scriptDir & "Watch-IconCache.ps1"

' Run style 0 = vbHide — fully invisible, no console window allocated
' False = do not wait for the process to finish (fire and forget)
oShell.Run "powershell.exe -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File """ & ps1Path & """", 0, False

Set oShell = Nothing
