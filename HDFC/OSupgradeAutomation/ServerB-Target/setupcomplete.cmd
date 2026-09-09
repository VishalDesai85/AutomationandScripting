@echo off
REM =============================================================================
REM IMPORTANT: Windows Setup's /PostOOBE switch REQUIRES this file to be named
REM EXACTLY "setupcomplete.cmd" (per Microsoft docs: "Local file path or UNC
REM network path to a file named setupcomplete.cmd, or to a folder that
REM contains setupcomplete.cmd."). Do NOT rename this file.
REM
REM Invoked automatically by Windows Setup (setup.exe /PostOOBE) once the new OS
REM completes OOBE/specialize processing. Creates a marker file that
REM Update-UpgradeStatus.ps1 watches for to know the upgrade has reached the
REM Second Boot (OOBE) phase, then immediately runs the status-update script so
REM the registry + D:\upgrade_status.json reflect it right away (rather than
REM waiting up to 5 minutes for the next scheduled poll).
REM =============================================================================

echo %DATE% %TIME% > "C:\ProgramData\OSUpgradeAutomation\postoobe.marker"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\OSUpgradeAutomation\Scripts\Update-UpgradeStatus.ps1"

exit /b 0
