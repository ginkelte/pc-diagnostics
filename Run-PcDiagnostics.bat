@echo off
REM PC Diagnostics Toolkit - one-click Full run.
REM Double-click this file: it asks for elevation once, then runs the full
REM diagnostic and keeps the window open so the report path can be read.
REM It passes no arguments; Full mode is the default. Parameterised runs are
REM for technical users and go through Invoke-PcDiagnostics.ps1 directly.
REM If the elevation prompt is declined this exits quietly with no artifact.
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$q=[char]34; $s='%~dp0Invoke-PcDiagnostics.ps1'; Start-Process -FilePath powershell.exe -WorkingDirectory '%~dp0' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',($q+$s+$q)) -Verb RunAs" >nul 2>&1
endlocal
exit /b 0
