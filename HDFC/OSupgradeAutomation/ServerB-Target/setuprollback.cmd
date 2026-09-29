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

REM NOTE: the unconditional "exit /b 0" below is DELIBERATE - do not "fix" it
REM by adding "if errorlevel 1 exit /b 1". Windows Setup treats this hook's
REM exit code as the hook's own success/failure, and this hook exists purely
REM to REPORT that a rollback happened. The rollback itself has ALREADY
REM occurred by the time this runs, so there is nothing here that can succeed
REM or fail in a way Setup could act on. If the status update above fails
REM transiently, the 2-minute OSUpgradePhaseMonitor task retries it; returning
REM non-zero would only add a spurious hook failure on top of the rollback
REM Setup is already reporting.
exit /b 0
