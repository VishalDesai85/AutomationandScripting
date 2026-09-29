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
        CompletedWithWarnings, or Failed). Missing/unreadable state is also
        treated as unsafe. It exits WITHOUT deleting anything, preserving
        visibility into a genuinely stuck upgrade. Use -Force to override
        the terminal-state check (not a registry access failure).
      - Removes the four scheduled tasks, the JSON status file, and the
        C:\ProgramData\OSUpgradeAutomation folder (logs, markers, staged
        scripts), then the registry key HKLM:\SOFTWARE\OSUpgradeAutomation.
        Failed cleanup retains registry metadata for retry. Reparse points
        and non-JSON status paths are refused even with -Force.
        The D:\UpgradeBackup folder is intentionally left alone -
        it is the state/policy backup, not disposable monitoring metadata,
        and cleanup here is only about the tracking artifacts.
      - Coordinates with the target starter using
        Global\OSUpgradeAutomation.StartTargetUpgrade, then takes the status
        mutex. An active starter prevents cleanup even with -Force.
      - Writes a durable transcript of what it did (or declined to do) to
        OSUpgradeCleanup_<stamp>.log - see the logging note in the body for
        why that file lives in the backup folder rather than under
        C:\ProgramData\OSUpgradeAutomation\Logs.

.PARAMETER Force
    Skip the terminal-state check regardless of Status. Path safety checks
    and failures reading existing registry metadata are never bypassed.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Remove-UpgradeArtifacts.ps1"
#>

[CmdletBinding()]
param(
    [switch]$Force
)

$script:RegRoot = "HKLM:\SOFTWARE\OSUpgradeAutomation"
$script:BaseDir = "C:\ProgramData\OSUpgradeAutomation"
$script:CleanupLogFile = $null

# =============================================================================
# DURABLE LOGGING (2026-09-26)
# =============================================================================
# This script's only output used to be Write-Output. That is fine when an
# operator runs it by hand, but its usual caller is the OSUpgradeAutoCleanup
# scheduled task, which discards stdout entirely - so the one action that
# DELETES all of an upgrade's tracking state left no record that it had run,
# what state it found, or why it declined to do anything. "The status JSON and
# registry key are gone" and "cleanup never ran" looked identical afterwards.
#
# The log deliberately does NOT go under $script:BaseDir: this script deletes
# that entire folder, so a log written there would survive only when cleanup
# FAILED - precisely backwards. It goes instead to the run's own backup folder
# (D:\UpgradeBackup\<run> by default), which is intentionally never
# auto-deleted and already holds OSUpgradeProgress.log, so the cleanup record
# files in alongside the rest of that run's durable history. Falls back to
# %SystemRoot%\Temp when no usable backup folder can be determined - e.g. a
# -Force run against half-initialised state, or the backup volume detached.
function Resolve-CleanupLogPath {
    $dir = $null
    try {
        if (Test-Path -LiteralPath $script:RegRoot) {
            $backupFolder = (Get-ItemProperty -LiteralPath $script:RegRoot -Name "BackupFolder" -ErrorAction SilentlyContinue).BackupFolder
            if ($backupFolder -and (Test-Path -LiteralPath $backupFolder -PathType Container)) { $dir = $backupFolder }
        }
    } catch {
        # Deliberately swallowed: an unreadable registry is itself something
        # worth logging, and we cannot log until this function has returned a
        # path. Fall through to the Temp fallback.
    }
    if (-not $dir) { $dir = Join-Path $env:SystemRoot "Temp" }
    return (Join-Path $dir ("OSUpgradeCleanup_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss")))
}

function Write-CleanupLog {
    param([string]$Message, [string]$Level = "INFO")
    # Keep emitting to stdout exactly as before, so an interactive run reads
    # the same and nothing downstream that captured this output changes.
    Write-Output $Message
    if (-not $script:CleanupLogFile) { return }
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    try {
        [System.IO.File]::AppendAllText($script:CleanupLogFile, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch {
        # Load-bearing catch: $ErrorActionPreference is 'Stop' in this script,
        # so without it a transient write failure (backup volume yanked
        # mid-run) would abort the cleanup partway through - leaving some
        # tasks unregistered and others not. Logging must never be the thing
        # that breaks the operation it is describing.
        Write-Output "[LOGGING] Could not append to $script:CleanupLogFile (continuing): $($_.Exception.Message)"
        $script:CleanupLogFile = $null
    }
}

function Assert-NoUpgradeReparsePoint {
    param([string]$Path, [switch]$Recurse)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing cleanup through reparse point '$Path'."
    }
    if ($Recurse -and $item.PSIsContainer) {
        foreach ($child in (Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
            Assert-NoUpgradeReparsePoint -Path $child.FullName -Recurse
        }
    }
}

function Assert-UpgradeCleanupPath {
    param([string]$Path, [switch]$StatusFile)
    if ($Path -notmatch '^[A-Za-z]:\\' -or
        ($StatusFile -and [IO.Path]::GetExtension($Path) -ne '.json')) {
        throw "Refusing unsafe artifact path '$Path'; status must be an absolute local JSON file."
    }
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current -ErrorAction Stop) {
            Assert-NoUpgradeReparsePoint -Path $current
        }
        $current = Split-Path -Path $current -Parent
    }
    if ($StatusFile -and (Test-Path -LiteralPath $Path -ErrorAction Stop) -and
        -not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction Stop)) {
        throw "Refusing to remove non-file status path '$Path'."
    }
}

function Invoke-UpgradeArtifactCleanup {
    param([switch]$Force)
    $taskNames = @("OSUpgradePhaseMonitor", "OSUpgradeRebootWatcher", "OSUpgradeAutoCleanup", "OSUpgradeSetupLaunch")
    $state = $null
    if (Test-Path -LiteralPath $script:RegRoot -ErrorAction Stop) {
        $state = Get-ItemProperty -LiteralPath $script:RegRoot -ErrorAction Stop
    }
    $status = $state.Status
    if (-not $Force -and $status -notin @("Completed", "CompletedWithWarnings", "Failed")) {
        Write-CleanupLog "Upgrade Status is '$status' (unknown or not terminal) - skipping cleanup without changing any artifacts. Use -Force only after verifying the run is no longer active."
        return
    }

    $statusJsonPath = $state.StatusJsonPath
    # Validate every deletion boundary before unregistering even one task.
    if ($statusJsonPath) { Assert-UpgradeCleanupPath -Path $statusJsonPath -StatusFile }
    Assert-UpgradeCleanupPath -Path $script:BaseDir
    if (Test-Path -LiteralPath $script:BaseDir -ErrorAction Stop) {
        Assert-NoUpgradeReparsePoint -Path $script:BaseDir -Recurse
    }

    Write-CleanupLog "Cleaning up OS upgrade tracking artifacts (last known Status: '$status')..."
    $tasks = @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object { $_.TaskName -in $taskNames })
    foreach ($task in $tasks) {
        Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
        Write-CleanupLog "Removed scheduled task: $($task.TaskName)"
    }
    if ($statusJsonPath -and (Test-Path -LiteralPath $statusJsonPath -ErrorAction Stop)) {
        Remove-Item -LiteralPath $statusJsonPath -Force -ErrorAction Stop
        Write-CleanupLog "Removed status JSON file: $statusJsonPath"
    }
    if (Test-Path -LiteralPath $script:BaseDir -ErrorAction Stop) {
        Remove-Item -LiteralPath $script:BaseDir -Recurse -Force -ErrorAction Stop
        Write-CleanupLog "Removed artifact folder: $script:BaseDir"
    }
    if (Test-Path -LiteralPath $script:RegRoot -ErrorAction Stop) {
        Remove-Item -LiteralPath $script:RegRoot -Recurse -Force -ErrorAction Stop
        Write-CleanupLog "Removed registry key: $script:RegRoot"
    }
    Write-CleanupLog "Cleanup complete. State/policy backups are left in place intentionally; remove them separately per your retention policy."
}

$ErrorActionPreference = 'Stop'

# Resolve the log destination BEFORE anything else: the backup-folder path
# comes out of the registry key this script may be about to delete, and every
# exit path below - including the two mutex deferrals and any Assert-* refusal
# - is worth a durable record. Scheduled-task invocations discard stdout, so
# without this the OSUpgradeAutoCleanup task's behaviour was unobservable.
$script:CleanupLogFile = Resolve-CleanupLogPath
Write-CleanupLog "=== OS upgrade artifact cleanup starting on $env:COMPUTERNAME (Force=$([bool]$Force)) ==="

$starterMutex = [System.Threading.Mutex]::new($false, "Global\OSUpgradeAutomation.StartTargetUpgrade")
$statusMutex = [System.Threading.Mutex]::new($false, "Global\OSUpgradeAutomation.Status")
$ownsStarterMutex = $false
$ownsStatusMutex = $false
try {
    try {
        $ownsStarterMutex = $starterMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $ownsStarterMutex = $true
    }
    if (-not $ownsStarterMutex) {
        Write-CleanupLog "Target starter is active; cleanup deferred even with -Force. Nothing was changed." "WARN"
        throw "Target starter is active; cleanup deferred even with -Force."
    }
    try {
        $ownsStatusMutex = $statusMutex.WaitOne(30000)
    } catch [System.Threading.AbandonedMutexException] {
        $ownsStatusMutex = $true
    }
    if (-not $ownsStatusMutex) {
        Write-CleanupLog "Status update is active (waited 30s for the status mutex); cleanup deferred. Nothing was changed - retry later." "WARN"
        throw "Status update is active; cleanup deferred. Retry later."
    }
    Invoke-UpgradeArtifactCleanup -Force:$Force
} catch {
    # Record WHAT stopped the cleanup, then rethrow unchanged so the caller's
    # exit code and error text are exactly what they were before. A partially
    # completed cleanup (e.g. tasks unregistered, registry key still present)
    # is the case this log matters most for.
    Write-CleanupLog "Cleanup did not complete: $($_.Exception.Message)" "ERROR"
    throw
} finally {
    if ($ownsStatusMutex) { $statusMutex.ReleaseMutex() }
    $statusMutex.Dispose()
    if ($ownsStarterMutex) { $starterMutex.ReleaseMutex() }
    $starterMutex.Dispose()
}
