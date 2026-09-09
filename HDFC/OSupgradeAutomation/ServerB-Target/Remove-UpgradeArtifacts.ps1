<#
.SYNOPSIS
    Cleans up all registry entries, the JSON status file, and scheduled tasks
    created by the OS in-place upgrade solution on Server B. Invoked
    automatically by the 'OSUpgradeAutoCleanup' scheduled task (registered by
    Start-TargetUpgrade.ps1, firing once -RetentionDays after kickoff), or
    on-demand/manually once a change ticket is verified and closed.

.DESCRIPTION
    Defensive by design:
      - Only deletes anything if Status is already terminal (Completed,
        CompletedWithWarnings, or Failed). If the upgrade still shows
        InProgress (e.g. stuck, or this ran too early), it logs and exits
        WITHOUT deleting anything - so you never lose visibility into a
        genuinely stuck upgrade. Use -Force to override this safety check.
      - Removes, in order: the three scheduled tasks (monitor, event watcher,
        auto-cleanup itself), the JSON status file, the registry key
        HKLM:\SOFTWARE\OSUpgradeAutomation, then the
        C:\ProgramData\OSUpgradeAutomation folder (logs, markers, staged
        scripts). The D:\UpgradeBackup folder is intentionally left alone -
        it is the state/policy backup, not disposable monitoring metadata,
        and cleanup here is only about the tracking artifacts.

.PARAMETER Force
    Skip the terminal-state check and delete everything regardless of Status.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Remove-UpgradeArtifacts.ps1"
#>

[CmdletBinding()]
param(
    [switch]$Force
)

$script:RegRoot = "HKLM:\SOFTWARE\OSUpgradeAutomation"
$script:BaseDir = "C:\ProgramData\OSUpgradeAutomation"

$taskNames        = @("OSUpgradePhaseMonitor", "OSUpgradeRebootWatcher", "OSUpgradeAutoCleanup", "OSUpgradeSetupLaunch")
$terminalStatuses = @("Completed", "CompletedWithWarnings", "Failed")

$status = $null
$statusJsonPath = $null
if (Test-Path $script:RegRoot) {
    $status = (Get-ItemProperty -Path $script:RegRoot -Name "Status" -ErrorAction SilentlyContinue).Status
    $statusJsonPath = (Get-ItemProperty -Path $script:RegRoot -Name "StatusJsonPath" -ErrorAction SilentlyContinue).StatusJsonPath
}

if (-not $Force -and $status -and ($status -notin $terminalStatuses)) {
    Write-Output "Upgrade Status is '$status' (not terminal) - skipping cleanup to avoid losing visibility into an in-progress upgrade. Re-run with -Force to override, or wait until it reaches a terminal state."
    # Unregister just the auto-cleanup task itself so it doesn't keep firing.
    Unregister-ScheduledTask -TaskName "OSUpgradeAutoCleanup" -Confirm:$false -ErrorAction SilentlyContinue
    exit 0
}

Write-Output "Cleaning up OS upgrade tracking artifacts (last known Status: '$status')..."

foreach ($t in $taskNames) {
    try {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction Stop
        Write-Output "Removed scheduled task: $t"
    } catch {
        Write-Output "Scheduled task '$t' not present or already removed."
    }
}

if ($statusJsonPath -and (Test-Path $statusJsonPath)) {
    try {
        Remove-Item -Path $statusJsonPath -Force -ErrorAction Stop
        Write-Output "Removed status JSON file: $statusJsonPath"
    } catch {
        Write-Output "WARNING: Failed to remove status JSON file '$statusJsonPath': $_"
    }
}

if (Test-Path $script:RegRoot) {
    try {
        Remove-Item -Path $script:RegRoot -Recurse -Force -ErrorAction Stop
        Write-Output "Removed registry key: $script:RegRoot"
    } catch {
        Write-Output "WARNING: Failed to remove registry key '$script:RegRoot': $_"
    }
} else {
    Write-Output "Registry key already absent: $script:RegRoot"
}

if (Test-Path $script:BaseDir) {
    try {
        Remove-Item -Path $script:BaseDir -Recurse -Force -ErrorAction Stop
        Write-Output "Removed artifact folder: $script:BaseDir"
    } catch {
        Write-Output "WARNING: Could not fully remove '$script:BaseDir' (may be in use by this running script) - safe to delete manually later; has no functional impact once the registry key and scheduled tasks are gone: $_"
    }
} else {
    Write-Output "Artifact folder already absent: $script:BaseDir"
}

Write-Output "Cleanup complete. Note: the D:\UpgradeBackup state/policy backup folder is left in place intentionally - remove it separately per your retention policy once no longer needed."
