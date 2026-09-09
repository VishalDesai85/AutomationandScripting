@echo off
REM =============================================================================
REM IMPORTANT: Windows Setup's /PostRollback switch REQUIRES this file to be
REM named EXACTLY "setuprollback.cmd" (per Microsoft docs: "Local file path or
REM UNC network path to a file named setuprollback.cmd, or to a folder that
REM contains setuprollback.cmd."). Do NOT rename this file - rollback would
REM never be detected/reported otherwise.
REM
REM Invoked automatically by Windows Setup (setup.exe /PostRollback) ONLY if
REM the upgrade fails and Windows automatically rolls back to the previous OS.
REM Creates a marker file, then runs the status-update script immediately so
REM the registry + D:\upgrade_status.json flip to Failed/RolledBack right away
REM instead of appearing "stuck" to the Server A monitoring loop.
REM =============================================================================

echo %DATE% %TIME% > "C:\ProgramData\OSUpgradeAutomation\rollback.marker"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\ProgramData\OSUpgradeAutomation\Scripts\Update-UpgradeStatus.ps1"

exit /b 0
