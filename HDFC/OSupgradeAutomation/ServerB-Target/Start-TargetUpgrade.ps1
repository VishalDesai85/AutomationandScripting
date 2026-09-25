<#
.SYNOPSIS
    TARGET EXECUTION SCRIPT - runs ON Server B (the server being upgraded).
    Performs mandatory safety pre-checks, backs up critical state, mounts the
    upgrade ISO (or reuses an already-mounted one), and launches Windows Setup
    in unattended in-place-upgrade mode. Registers scheduled tasks so progress
    can keep being tracked across the multiple reboots that follow.

.DESCRIPTION
    This script is normally copied to Server B and invoked remotely by
    Start-RemoteUpgradeOrchestrator.ps1 (running on Server A), but it is fully
    self-contained and can also be run interactively/locally on Server B for
    testing.

    Flow:
      1. Bootstrap folders + logging.
      2. Hard-fail pre-checks (Section 1 of the spec). ANY failure here stops
         the script immediately - nothing below runs.
      3. Non-blocking checks (patch level / VMware Tools / RDS CAL) - these can
         warn-and-terminate (patch level, unless -SkipPatchCheckLab is used) or
         warn-only (RDS CAL pointer) per the customer's exact ask.
      4. Backup of registry hives, local GPO/SECPOL, and (if applicable) the
         RDS CAL licensing database to a folder on a drive OTHER than C:.
      5. Locate/mount the upgrade ISO and locate setup.exe.
      6. Launch setup.exe unattended, register the phase/progress monitor,
         the reboot-event watcher, and the retention-based auto-cleanup task.

.NOTES
    Author       : Generated for OS Upgrade Automation (HDFC)
    Requires     : Windows Server 2019/2022, PowerShell 5.1+, run elevated (SYSTEM
                   or local Administrator) on Server B.
    Shared paths : Must stay in sync with Update-UpgradeStatus.ps1 and
                   Remove-UpgradeArtifacts.ps1 (registry root, base dir, JSON path,
                   scheduled task names).

.PARAMETER IsoFolder
    Folder on Server B containing the target OS ISO. Default: D:\ISO
    If exactly one .iso file exists there, it is used automatically.

.PARAMETER MinFreeSpaceGB
    Minimum required free space on the system drive (C:) before proceeding.
    Default: 32 GB (per spec; configurable).

.PARAMETER BackupRoot
    Root folder for the state/policy backup. MUST be on a drive other than C:.
    Default: D:\UpgradeBackup

.PARAMETER StatusJsonPath
    Path to the JSON status file that Server A reads directly (e.g. via the
    D$ admin share) when WinRM/CIM is unavailable during reboots.
    Default: D:\upgrade_status.json

.PARAMETER RetentionDays
    Days to retain the registry status key + JSON file + ProgramData artifacts
    after the upgrade reaches a terminal state, before automatic cleanup fires.
    Default: 14.

.PARAMETER DisableAutoCleanup
    Skip registering the auto-cleanup scheduled task; cleanup then becomes a
    manual/on-demand action via Remove-UpgradeArtifacts.ps1 -Force.

.PARAMETER SkipPatchCheckLab
    LAB/TEST-ONLY OVERRIDE. When the patch-level check finds the server is not
    current, normal behavior is to log a warning AND terminate. Pass this
    switch to downgrade that to a warning-only (proceed anyway) - intended
    strictly for lab/non-production validation runs, never production.

.PARAMETER SkipSystemStateBackup
    Skip backup task 8 of 8 (the wbadmin system state backup). That task is
    by far the slowest and largest part of the backup stage, so skipping it
    is useful for repeat lab runs, or where an external/enterprise backup
    product (or a VM snapshot) already provides an equivalent restore point.
    Everything else in the backup stage still runs: registry hives, GPO,
    secedit, gpresult, RDS CAL DB, and the pre-upgrade services snapshot.
    Think carefully before using this in production - system state is the
    artifact you would need for a bare-metal/AD-level restore if the upgrade
    goes badly.

.PARAMETER MinVMwareToolsVersion
    Minimum acceptable VMware Tools version when Server B is a VMware VM.
    Default: "12.0.0". Ignored entirely on Hyper-V/physical hardware.

.PARAMETER UseControlledReboot
    When set, setup.exe is launched with /NoReboot and this script explicitly
    triggers the first restart after a short grace delay, giving you a
    controlled maintenance-window reboot instead of letting Setup reboot
    immediately on its own schedule. Default: off (Setup manages its own
    reboots end-to-end, which is the simpler/most common pattern).

.EXAMPLE
    Local/manual test run on Server B:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-TargetUpgrade.ps1" -IsoFolder "D:\ISO"

.EXAMPLE
    Lab run bypassing only the patch-currency hard stop:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-TargetUpgrade.ps1" -SkipPatchCheckLab

.EXAMPLE
    Repeat lab run, skipping the slow system state backup:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-TargetUpgrade.ps1" -SkipPatchCheckLab -SkipSystemStateBackup
#>

[CmdletBinding()]
param(
    [string]$IsoFolder          = "D:\ISO",
    [int]   $MinFreeSpaceGB     = 32,
    [string]$BackupRoot         = "D:\UpgradeBackup",
    [string]$StatusJsonPath     = "D:\upgrade_status.json",
    [int]   $RetentionDays      = 14,
    [switch]$DisableAutoCleanup,
    [switch]$SkipPatchCheckLab,
    [switch]$SkipSystemStateBackup,
    [string]$MinVMwareToolsVersion = "12.0.0",
    [switch]$UseControlledReboot,
    [int]   $MaxPatchAgeDays    = 60
)

$ErrorActionPreference = "Stop"

# =============================================================================
# SECTION 0 - SHARED CONSTANTS (must match Update-UpgradeStatus.ps1 and
# Remove-UpgradeArtifacts.ps1 exactly - these are the "contract" between the
# scripts and between Server A / Server B).
# =============================================================================
$script:RegRoot     = "HKLM:\SOFTWARE\OSUpgradeAutomation"
$script:BaseDir     = "C:\ProgramData\OSUpgradeAutomation"
$script:ScriptsDir  = Join-Path $script:BaseDir "Scripts"
$script:LogDir      = Join-Path $script:BaseDir "Logs"
$script:StatusJson  = $StatusJsonPath
$script:MarkerOOBE  = Join-Path $script:BaseDir "postoobe.marker"
$script:MarkerRB    = Join-Path $script:BaseDir "rollback.marker"
$script:StatusHelper = Join-Path $PSScriptRoot "OSUpgradeStatus.ps1"

$script:TaskMonitor   = "OSUpgradePhaseMonitor"
$script:TaskReboot    = "OSUpgradeRebootWatcher"
$script:TaskCleanup   = "OSUpgradeAutoCleanup"
$script:TaskSetupRun  = "OSUpgradeSetupLaunch"

# Master run log - everything (pre-checks, backup, mount, launch) is appended
# here so there is a single, complete audit trail for this run, as requested.
foreach ($d in @($script:BaseDir, $script:ScriptsDir, $script:LogDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$script:RunStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:LogFile  = Join-Path $script:LogDir "OSUpgradeAutomation_$($script:RunStamp).log"

# =============================================================================
# SECTION 1 - HELPER FUNCTIONS (logging, registry+JSON status writer)
# =============================================================================

function Write-Log {
    <# Central logger - writes to console AND the master run log file. #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR","PASS","FAIL")][string]$Level = "INFO"
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "FAIL"  { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "PASS"  { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
}

# Both target-side processes use one JSON schema and one monotonic end-to-end
# percentage model from this shared helper.
if (-not (Test-Path $script:StatusHelper)) {
    throw "Required shared status helper not found: $script:StatusHelper"
}
. $script:StatusHelper

# Hold this named mutex for the lifetime of the kickoff PowerShell process.
# A previous WinRM caller can disconnect while DISM/SFC is still running; a
# second kickoff must not start another precheck sequence against the same
# registry/status contract. Windows releases the mutex when this process exits.
$script:KickoffMutex = New-Object System.Threading.Mutex($false, "Global\OSUpgradeAutomationKickoff")
$kickoffLockTaken = $false
try {
    $kickoffLockTaken = $script:KickoffMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $kickoffLockTaken = $true
}
if (-not $kickoffLockTaken) {
    throw "Another Start-TargetUpgrade.ps1 process is still running on $env:COMPUTERNAME. Wait for that kickoff/precheck process to finish or investigate it before retrying."
}

function Enable-BackupPrivilege {
    <#
    Enables SeBackupPrivilege + SeRestorePrivilege on THIS process's token.
    Local Administrators are GRANTED these privileges by Windows, but they
    sit DISABLED by default until a process explicitly turns them on via
    AdjustTokenPrivileges - this is exactly why 'reg.exe export HKLM\SAM' and
    especially 'HKLM\SECURITY' normally fail with Access Denied even when
    running as a local admin: HKLM\SECURITY's ACL denies read access to
    everyone except SYSTEM/TrustedInstaller, but SeBackupPrivilege (once
    enabled) makes Windows bypass that ACL check specifically for backup-
    style operations such as RegSaveKeyEx, which is what 'reg.exe export'
    uses under the hood - no need to actually be SYSTEM.
    Child processes (like reg.exe) spawned AFTER this runs inherit the
    enabled privilege state via their duplicated token, so this only needs
    to run ONCE per session, before the registry export step below.
    Best-effort / non-fatal: if the current token genuinely doesn't hold the
    privilege (e.g. a constrained/JEA context, or - on an interactive local
    console - a UAC-filtered standard-user token rather than a full admin
    token), this simply returns $false and the existing non-blocking WARN
    already in place for SAM/SECURITY export failures still applies exactly
    as before - this is a pure enhancement, not a required dependency.
    #>
    try {
        if (-not ("Win32.TokenPrivilege" -as [type])) {
            Add-Type -Namespace Win32 -Name TokenPrivilege -MemberDefinition @'
[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out long lpLuid);
[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, byte[] NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);
'@
        }
        $TOKEN_ADJUST_PRIVILEGES = 0x0020
        $TOKEN_QUERY             = 0x0008
        $SE_PRIVILEGE_ENABLED    = 0x00000002

        $hToken = [IntPtr]::Zero
        $procHandle = [System.Diagnostics.Process]::GetCurrentProcess().Handle
        if (-not [Win32.TokenPrivilege]::OpenProcessToken($procHandle, $TOKEN_ADJUST_PRIVILEGES -bor $TOKEN_QUERY, [ref]$hToken)) {
            return $false
        }

        $allGood = $true
        foreach ($privName in @("SeBackupPrivilege","SeRestorePrivilege")) {
            $luid = 0L
            if (-not [Win32.TokenPrivilege]::LookupPrivilegeValue($null, $privName, [ref]$luid)) { $allGood = $false; continue }
            # Manually build the TOKEN_PRIVILEGES struct as a byte[] (PrivilegeCount(4) + LUID(8) + Attributes(4)):
            $buffer = New-Object byte[] 16
            [BitConverter]::GetBytes([int]1).CopyTo($buffer, 0)
            [BitConverter]::GetBytes([long]$luid).CopyTo($buffer, 4)
            [BitConverter]::GetBytes([int]$SE_PRIVILEGE_ENABLED).CopyTo($buffer, 12)
            $adjustOk = [Win32.TokenPrivilege]::AdjustTokenPrivileges($hToken, $false, $buffer, 16, [IntPtr]::Zero, [IntPtr]::Zero)
            # IMPORTANT Win32 gotcha: AdjustTokenPrivileges returns TRUE even when it
            # silently failed to enable a privilege the token doesn't actually hold -
            # you MUST also check GetLastWin32Error() for ERROR_NOT_ALL_ASSIGNED (1300)
            # to detect that case; the boolean return value alone is not reliable here
            # (verified empirically - a UAC-filtered/standard token returns True + 1300).
            $lastErr = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            if (-not $adjustOk -or $lastErr -eq 1300) { $allGood = $false }
        }
        return $allGood
    } catch {
        return $false
    }
}

Write-Log "===================================================================="
Write-Log "Start-TargetUpgrade.ps1 invoked on $env:COMPUTERNAME"
Write-Log "===================================================================="

# =============================================================================
# SECTION 1b - DETECT & CLEAN UP A STALE PRIOR ATTEMPT
# =============================================================================
# A previous run can leave behind registry state / scheduled tasks / a
# $WINDOWS.~BT folder without ever reaching a terminal Status - e.g. the
# OneSettings-network-timeout bug (setup.exe self-cancelled ~30-40 min in,
# before ever rebooting) left Status stuck at "InProgress" forever, and
# setup.exe itself can refuse to start again on top of a leftover
# $WINDOWS.~BT (observed exit code 1618 = ERROR_INSTALL_ALREADY_RUNNING).
# Starting a fresh attempt on top of that leftover state either confuses
# phase detection or blocks setup.exe outright. So: check what's there
# first, and only auto-clean it if it does NOT look like a genuinely active
# upgrade - never touch state that has real evidence of being alive.
$priorPhase  = (Get-ItemProperty $script:RegRoot -Name Phase  -ErrorAction SilentlyContinue).Phase
$priorStatus = (Get-ItemProperty $script:RegRoot -Name Status -ErrorAction SilentlyContinue).Status
$btPath      = "$env:SystemDrive\`$WINDOWS.~BT"

if ($priorStatus) {
    $setupIsRunning = [bool](Get-Process -Name "setup","SetupHost","SetupPrep" -ErrorAction SilentlyContinue)
    $pantherLog      = Join-Path $btPath "Sources\Panther\setupact.log"
    $pantherFreshMin = if (Test-Path $pantherLog) { ((Get-Date) - (Get-Item $pantherLog).LastWriteTime).TotalMinutes } else { [double]::PositiveInfinity }
    # NOTE: Status "InProgress" alone is NOT trustworthy (see above) - real
    # activity evidence is a live setup process, or a setupact.log written
    # to within the last 5 minutes. Real Setup activity writes to that log
    # every few seconds while genuinely working (observed sub-5-second
    # cadence in practice) - a gap even in the high teens of minutes is
    # actually strong evidence the attempt already died, not that it's
    # still active. (A looser 20-min threshold previously let an 18.8-min-
    # stale attempt slip through as a false positive - fixed here.)
    $looksActive = $setupIsRunning -or ($pantherFreshMin -lt 5)

    if ($priorStatus -eq "InProgress" -and $looksActive) {
        throw "A prior upgrade attempt looks genuinely ACTIVE on $env:COMPUTERNAME (Phase=$priorPhase, Status=InProgress, setup process running=$setupIsRunning, setupact.log age=$([math]::Round($pantherFreshMin,1)) min). Refusing to start a new attempt on top of it - wait for it to finish, or investigate manually if you're certain it's actually dead."
    } else {
        Write-Log "Detected leftover state from a prior attempt (Phase=$priorPhase, Status=$priorStatus) that does NOT look active (setup process running=$setupIsRunning, setupact.log age=$([math]::Round($pantherFreshMin,1)) min) - cleaning it up before starting fresh." "WARN"
        Unregister-ScheduledTask -TaskName @($script:TaskMonitor, $script:TaskReboot, $script:TaskCleanup, $script:TaskSetupRun) -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -Path $script:RegRoot -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $script:MarkerOOBE, $script:MarkerRB -Force -ErrorAction SilentlyContinue
        if (Test-Path $btPath) {
            $staleName = "$($btPath).stale_$(Get-Date -Format 'yyyyMMddHHmmss')"
            try {
                Rename-Item -Path $btPath -NewName (Split-Path $staleName -Leaf) -Force -ErrorAction Stop
                Write-Log "Renamed stale $btPath -> $staleName so Windows Setup doesn't see a leftover install and refuse to start (ERROR_INSTALL_ALREADY_RUNNING)." "WARN"
            } catch {
                Write-Log "Could not rename stale $btPath (non-blocking - setup.exe may still refuse to start; remove it manually if so): $_" "WARN"
            }
        }
        Write-Log "Cleanup of prior attempt complete - proceeding with a fresh run."
    }
}

$runStartedAt = Get-Date
Set-UpgradeRegistryValue -Name "RunId" -Value ([guid]::NewGuid().ToString())
Set-UpgradeRegistryValue -Name "StartTime" -Value ($runStartedAt.ToString("yyyy-MM-dd HH:mm:ss"))
Set-UpgradeRegistryValue -Name "StartTimeUtc" -Value ([DateTimeOffset]$runStartedAt).ToUniversalTime().ToString("o")
Set-UpgradeRegistryValue -Name "StatusJsonPath" -Value $script:StatusJson
Set-UpgradeRegistryValue -Name "RebootCount" -Value 0 -Type DWord
Update-UpgradeBootEvidence | Out-Null
Set-Phase -Phase 1 -PhaseName "Pre-Upgrade Assessment" -Status "InProgress" `
    -PercentComplete 0 -PercentSource "Measured" -ProgressSource "StageBoundary" -ProgressFreshness "Milestone"

# =============================================================================
# SECTION 2 - HARD-FAIL PRE-CHECKS (spec Section 1)
# Each check appends to $hardFailures. ANY entry there => log + throw + stop,
# no exceptions, before Section 3 (backup) or Section 4 (ISO/setup) ever runs.
# =============================================================================
$hardFailures = New-Object System.Collections.Generic.List[string]
$warnings     = New-Object System.Collections.Generic.List[string]
$preCheckLog  = @()   # human-readable PASS/FAIL/WARN lines for the dedicated pre-check report

# TASK-COUNT-BASED PERCENTAGE (2026-07-24, customer request): unlike Stage
# 3's telemetry-based percentage, Stage 1 has no live "how far through am I"
# signal of its own - but the NUMBER OF DISCRETE CHECKS is a real, countable
# quantity, so "N of M checks done" is a genuine measurement, not a guess.
# IMPORTANT: keep $totalPrecheckSteps in sync with the actual number of
# DISTINCT check NAMES passed to Add-PreCheckResult below - currently 14:
# 1) Not a Domain Controller, 2) Not a Failover Cluster node, 3) C: free disk
# space, 4) No pending reboot, 5) Component store health (DISM ScanHealth),
# 6) System file integrity (SFC /scannow), 7) Locate setup.exe on ISO media,
# 8) ISO edition matches current OS, 9) Target media build is newer than
# current OS build, 10) OS activation/licensing healthy, 11) Patch level
# up-to-date, 12) VMware Tools check, 13) RDS Session Host CAL license
# server check, 14) Orphaned local user profiles. Bump this number (and the
# comment above) whenever a check is added/removed - each name should only
# ever be reported ONCE per run (exactly one PASS/WARN/FAIL branch fires per
# check), so a simple running counter incremented on every
# Add-PreCheckResult call accurately reflects "how many of the total checks
# have completed".
$totalPrecheckSteps = 14
$script:precheckStepsDone = 0

function Add-PreCheckResult {
    param([string]$Name, [ValidateSet("PASS","WARN","FAIL")][string]$Result, [string]$Detail = "")
    $line = "{0,-45} : {1,-5} {2}" -f $Name, $Result, $Detail
    $script:preCheckLog += $line
    switch ($Result) {
        "PASS" { Write-Log "$Name : PASS $Detail" "PASS" }
        "WARN" { Write-Log "$Name : WARN $Detail" "WARN"; $warnings.Add("$Name`: $Detail") }
        "FAIL" { Write-Log "$Name : FAIL $Detail" "FAIL"; $hardFailures.Add("$Name`: $Detail") }
    }
    # Every named check - regardless of PASS/WARN/FAIL - represents one
    # completed unit of precheck work, so the percentage still climbs even
    # on a WARN/FAIL (a check that failed was still WORKED THROUGH, it just
    # didn't pass) - it only stops climbing if the whole run throws/stops
    # due to a hard failure, which is an accurate reflection of reality.
    $script:precheckStepsDone++
    $pct = [math]::Min(100, [int](100.0 * $script:precheckStepsDone / $totalPrecheckSteps))
    Set-Phase -Phase 1 -PhaseName "Pre-Upgrade Assessment" -Status "InProgress" -PercentComplete $pct -PercentSource "Measured" -Notes "Check $script:precheckStepsDone/$totalPrecheckSteps complete: $Name ($Result)"
}

Write-Log "----- Running mandatory pre-checks -----"

# --- 2.1 Domain Controller guard --------------------------------------------
try {
    $isDC = (Get-CimInstance Win32_ComputerSystem).DomainRole -in 4,5   # 4=Backup DC, 5=Primary DC
    $adFeature = $null
    try { $adFeature = Get-WindowsFeature -Name AD-Domain-Services -ErrorAction SilentlyContinue } catch {}
    if ($isDC -or ($adFeature -and $adFeature.Installed)) {
        Add-PreCheckResult -Name "Not a Domain Controller" -Result "FAIL" -Detail "AD DS role installed / DomainRole indicates DC. In-place upgrade is not supported for DCs."
    } else {
        Add-PreCheckResult -Name "Not a Domain Controller" -Result "PASS"
    }
} catch {
    Add-PreCheckResult -Name "Not a Domain Controller" -Result "FAIL" -Detail "Could not determine DC status: $_"
}

# --- 2.2 Failover Cluster guard ----------------------------------------------
try {
    $clusFeature = $null
    try { $clusFeature = Get-WindowsFeature -Name Failover-Clustering -ErrorAction SilentlyContinue } catch {}
    $clusSvc = Get-Service -Name ClusSvc -ErrorAction SilentlyContinue
    if (($clusFeature -and $clusFeature.Installed) -or ($clusSvc -and $clusSvc.Status -eq "Running")) {
        Add-PreCheckResult -Name "Not a Failover Cluster node" -Result "FAIL" -Detail "Failover-Clustering feature installed and/or ClusSvc running. Use Cluster-Aware Updating / rolling OS upgrade instead."
    } else {
        Add-PreCheckResult -Name "Not a Failover Cluster node" -Result "PASS"
    }
} catch {
    Add-PreCheckResult -Name "Not a Failover Cluster node" -Result "FAIL" -Detail "Could not determine cluster status: $_"
}

# --- 2.3 Free disk space on C: ----------------------------------------------
try {
    $sysDrive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
    $freeGB = [math]::Round($sysDrive.Free / 1GB, 1)
    if ($freeGB -lt $MinFreeSpaceGB) {
        Add-PreCheckResult -Name "C: free disk space" -Result "FAIL" -Detail "$freeGB GB free, $MinFreeSpaceGB GB required."
    } else {
        Add-PreCheckResult -Name "C: free disk space" -Result "PASS" -Detail "$freeGB GB free (>= $MinFreeSpaceGB GB required)."
    }
} catch {
    Add-PreCheckResult -Name "C: free disk space" -Result "FAIL" -Detail "Could not determine free space: $_"
}

# --- 2.4 Pending reboot check -------------------------------------------------
try {
    $pendingReboot = Get-UpgradePendingRebootState
    $pendingReasons = @($pendingReboot.Reasons)
    if ($pendingReasons.Count -gt 0) {
        Add-PreCheckResult -Name "No pending reboot" -Result "FAIL" -Detail ($pendingReasons -join "; ")
    } else {
        Add-PreCheckResult -Name "No pending reboot" -Result "PASS"
    }
} catch {
    Add-PreCheckResult -Name "No pending reboot" -Result "FAIL" -Detail "Could not evaluate pending-reboot state: $_"
}

# --- 2.5 Component store health (DISM ScanHealth) ----------------------------
# ScanHealth is a fast, read-only pass (unlike /RestoreHealth). BLOCKING on
# confirmed corruption (2026-07-28, explicit customer decision - reverted
# the brief 2026-07-26 WARN-only experiment: genuine component-store
# corruption is a real, documented root cause of in-place-upgrade failures,
# unlike e.g. orphaned profiles - so it stops the run just like that check
# does). All 13 pre-checks still run to completion regardless (this check
# does NOT `throw` here - it only appends to $hardFailures, same as every
# other check - see Section 2c's single aggregated throw at the very end),
# so the admin sees every failing item in one shot and can resolve them all
# before re-initiating the upgrade. Only genuinely INCONCLUSIVE outcomes
# (DISM couldn't even run, or its output couldn't be parsed) stay WARN -
# uncertainty about whether a problem exists is not the same as a confirmed
# finding.
try {
    Write-Log "Running 'Dism /Online /Cleanup-Image /ScanHealth' (read-only scan, may take a few minutes)..."
    $dismOutput = & Dism.exe /Online /Cleanup-Image /ScanHealth 2>&1 | Out-String
    Add-Content -Path (Join-Path $script:LogDir "DismScanHealth_$($script:RunStamp).log") -Value $dismOutput -Encoding UTF8
    if ($dismOutput -match "No component store corruption detected") {
        Add-PreCheckResult -Name "Component store health (DISM ScanHealth)" -Result "PASS"
    } elseif ($dismOutput -match "component store (is repairable|corruption)") {
        Add-PreCheckResult -Name "Component store health (DISM ScanHealth)" -Result "FAIL" -Detail "Corruption detected - BLOCKING. Run 'Dism /Online /Cleanup-Image /RestoreHealth' then SFC /scannow to repair, confirm both come back clean, then re-initiate the upgrade - see DismScanHealth_$($script:RunStamp).log."
    } else {
        Add-PreCheckResult -Name "Component store health (DISM ScanHealth)" -Result "WARN" -Detail "Could not conclusively parse DISM output - see DismScanHealth_$($script:RunStamp).log. Proceeding, but review manually."
    }
} catch {
    Add-PreCheckResult -Name "Component store health (DISM ScanHealth)" -Result "WARN" -Detail "DISM scan failed to run (non-blocking): $_"
}

# --- 2.5b System file integrity (SFC /scannow) -------------------------------
# Added 2026-07-26 (customer request), alongside DISM ScanHealth above.
# BLOCKING on confirmed corruption (2026-07-28, same decision/reasoning as
# DISM above - reverted the brief WARN-only experiment): SFC can both
# DETECT and (unlike DISM ScanHealth) actually REPAIR corrupt protected
# files itself, but even an auto-repaired finding means the system had
# integrity problems that should be verified clean (re-run SFC/DISM to
# confirm) before attempting something as major as an OS upgrade. Its
# console summary alone can also be vague, so this also scans CBS.log (the
# same underlying log both DISM and SFC write detailed per-file results to)
# for `[SR]` (System Repair/SFC-specific) entries logged DURING this
# specific scan (filtered by timestamp, since CBS.log is a large cumulative
# log spanning the machine's whole lifetime) mentioning an
# unrepairable/corrupt file, as supplementary detail alongside SFC's own
# summary line. Only genuinely INCONCLUSIVE outcomes (SFC couldn't run at
# all, e.g. another servicing operation in progress, or its output couldn't
# be parsed) stay WARN.
try {
    $cbsLogPath   = Join-Path $env:WINDIR "Logs\CBS\CBS.log"
    $sfcScanStart = Get-Date
    Write-Log "Running 'sfc /scannow' (may take several minutes)..."
    $sfcOutput = & sfc.exe /scannow 2>&1 | Out-String
    $sfcLogPath = Join-Path $script:LogDir "SfcScanNow_$($script:RunStamp).log"
    Add-Content -Path $sfcLogPath -Value $sfcOutput -Encoding UTF8

    # Best-effort CBS.log supplementary scan - non-fatal if it fails or the
    # log is missing/inaccessible; SFC's own summary line is still the
    # primary signal either way.
    $cbsErrorCount = 0
    try {
        if (Test-Path $cbsLogPath) {
            Get-Content -Path $cbsLogPath -Tail 20000 -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_ -match '^(?<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})' -and $_ -match '(?i)\[SR\].*(cannot repair|corrupt)') {
                    $lineTime = $null
                    if ([datetime]::TryParseExact($Matches.ts, "yyyy-MM-dd HH:mm:ss", $null, [System.Globalization.DateTimeStyles]::None, [ref]$lineTime)) {
                        if ($lineTime -ge $sfcScanStart) { $cbsErrorCount++ }
                    }
                }
            }
        }
    } catch {
        Write-Log "Could not analyze CBS.log for supplementary SFC detail (non-blocking): $_" "WARN"
    }

    if ($sfcOutput -match "did not find any integrity violations") {
        Add-PreCheckResult -Name "System file integrity (SFC /scannow)" -Result "PASS" -Detail "No integrity violations found."
    } elseif ($sfcOutput -match "found corrupt files and successfully repaired") {
        Add-PreCheckResult -Name "System file integrity (SFC /scannow)" -Result "FAIL" -Detail "Corrupt files were found (SFC repaired them automatically, but this confirms the system had integrity problems - CBS.log [SR] entries this run: $cbsErrorCount). BLOCKING - review $sfcLogPath and CBS.log, re-run SFC/DISM to confirm a clean result, then re-initiate the upgrade."
    } elseif ($sfcOutput -match "unable to fix some of them") {
        Add-PreCheckResult -Name "System file integrity (SFC /scannow)" -Result "FAIL" -Detail "Corrupt files found that SFC could NOT fully repair (CBS.log [SR] 'cannot repair'-style entries this run: $cbsErrorCount). BLOCKING - review $sfcLogPath and CBS.log, run 'Dism /Online /Cleanup-Image /RestoreHealth' then SFC /scannow again to repair, confirm clean, then re-initiate the upgrade."
    } elseif ($sfcOutput -match "could not perform the requested operation") {
        Add-PreCheckResult -Name "System file integrity (SFC /scannow)" -Result "WARN" -Detail "SFC could not run (e.g. another servicing operation in progress, or requires Safe Mode) - proceeding anyway (non-blocking); see $sfcLogPath."
    } else {
        Add-PreCheckResult -Name "System file integrity (SFC /scannow)" -Result "WARN" -Detail "Could not conclusively parse SFC output (CBS.log [SR] entries this run: $cbsErrorCount) - see $sfcLogPath. Proceeding, but review manually."
    }
} catch {
    Add-PreCheckResult -Name "System file integrity (SFC /scannow)" -Result "WARN" -Detail "SFC scan failed to run (non-blocking): $_"
}

# --- 2.6 Locate ISO / setup.exe + Edition match ------------------------------
# Mounting happens here (once) so the edition can be verified against the
# actual media; the SAME mounted drive is reused later to launch setup.exe -
# it is not re-mounted a second time.
function Get-OrMountIso {
    <#
    Resolves the ISO to use from $IsoFolder, reuses an already-mounted copy of
    that exact ISO if one exists (per spec: "if already mounted... do not
    mount, proceed with whichever drive is mounted"), otherwise mounts it and
    resolves the drive letter Windows assigns (never hardcoded).
    #>
    param([string]$IsoFolder)

    if (-not (Test-Path $IsoFolder)) { throw "ISO folder '$IsoFolder' does not exist." }
    $isoFiles = Get-ChildItem -Path $IsoFolder -Filter "*.iso" -File -ErrorAction SilentlyContinue
    if (-not $isoFiles -or $isoFiles.Count -eq 0) { throw "No .iso file found in '$IsoFolder'." }
    if ($isoFiles.Count -gt 1) {
        Write-Log "Multiple .iso files found in '$IsoFolder' - using the first one alphabetically: $($isoFiles[0].Name)" "WARN"
    }
    $isoPath = $isoFiles[0].FullName

    # Check whether this exact ISO is already mounted (by ImagePath match).
    # IMPORTANT: always call Get-DiskImage WITH -ImagePath. Get-DiskImage has no
    # "list every mounted image" mode - ImagePath is a mandatory parameter, so
    # omitting it makes PowerShell prompt interactively ("Supply values for the
    # following parameters: ImagePath[0]:") and hang the whole run waiting for
    # console input. Since we already know the exact candidate ISO path from the
    # folder scan above, we can query it directly instead of enumerating all
    # mounted images.
    $existingImage = Get-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
    if ($existingImage -and $existingImage.Attached) {
        $vol = $existingImage | Get-Volume -ErrorAction SilentlyContinue
        if ($vol -and $vol.DriveLetter) {
            Write-Log "ISO '$isoPath' is already mounted at $($vol.DriveLetter): - reusing it, not re-mounting."
            return [pscustomobject]@{ IsoPath = $isoPath; DriveLetter = $vol.DriveLetter; SetupPath = "$($vol.DriveLetter):\setup.exe" }
        }
    }

    Write-Log "Mounting ISO: $isoPath"
    Mount-DiskImage -ImagePath $isoPath -PassThru | Out-Null
    $driveLetter = $null
    for ($i = 0; $i -lt 15 -and -not $driveLetter; $i++) {
        Start-Sleep -Seconds 1
        $vol = Get-DiskImage -ImagePath $isoPath | Get-Volume -ErrorAction SilentlyContinue
        if ($vol -and $vol.DriveLetter) { $driveLetter = $vol.DriveLetter }
    }
    if (-not $driveLetter) { throw "ISO mounted but Windows did not report a drive letter within 15 seconds." }
    return [pscustomobject]@{ IsoPath = $isoPath; DriveLetter = $driveLetter; SetupPath = "${driveLetter}:\setup.exe" }
}

$isoInfo = $null
try {
    $isoInfo = Get-OrMountIso -IsoFolder $IsoFolder
    if (-not (Test-Path $isoInfo.SetupPath)) {
        Add-PreCheckResult -Name "Locate setup.exe on ISO media" -Result "FAIL" -Detail "setup.exe not found at $($isoInfo.SetupPath)."
    } else {
        Add-PreCheckResult -Name "Locate setup.exe on ISO media" -Result "PASS" -Detail "Found at $($isoInfo.SetupPath)."
    }
} catch {
    Add-PreCheckResult -Name "Locate setup.exe on ISO media" -Result "FAIL" -Detail "$_"
}

if ($isoInfo -and (Test-Path $isoInfo.SetupPath)) {
    try {
        $currentEdition = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name EditionID -ErrorAction SilentlyContinue).EditionID
        # InstallationType ("Server" = full/Desktop Experience, "Server Core" = Core)
        # is the ONLY field that distinguishes a GUI edition from its Core twin -
        # both share the exact same EditionId (e.g. both "Windows Server 2022
        # Datacenter" and "...Datacenter (Desktop Experience)" report EditionId
        # "ServerDatacenter"). Matching on EditionId alone can silently pick the
        # WRONG image (e.g. Core when the source is Desktop Experience), which
        # would upgrade a GUI server into a headless Core install.
        $currentInstallationType = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name InstallationType -ErrorAction SilentlyContinue).InstallationType
        $wimPath = Join-Path (Split-Path $isoInfo.SetupPath -Parent) "sources\install.wim"
        if (-not (Test-Path $wimPath)) { $wimPath = Join-Path (Split-Path $isoInfo.SetupPath -Parent) "sources\install.esd" }

        if (-not (Test-Path $wimPath)) {
            Add-PreCheckResult -Name "ISO edition matches current OS ($currentEdition, $currentInstallationType)" -Result "WARN" -Detail "Could not locate install.wim/install.esd to verify - proceeding, verify manually."
            Add-PreCheckResult -Name "Target media build is newer than current OS build" -Result "WARN" -Detail "Could not locate install.wim/install.esd to determine the media's build number - verify manually that this media is for a NEWER OS version before relying on this run."
        } else {
            # IMPORTANT: Get-WindowsImage -ImagePath (with NO -Index) only returns a
            # lightweight listing - ImageIndex/ImageName/ImageDescription are populated,
            # but EditionId/Version/InstallationType are ALWAYS blank in that mode. Those
            # detailed fields are only populated when -Index <N> is also supplied for a
            # SPECIFIC image. So we first enumerate the available indices, then query
            # each one individually to get its real EditionId/Version/InstallationType.
            $indexList = Get-WindowsImage -ImagePath $wimPath -ErrorAction Stop
            $images = foreach ($idx in $indexList) {
                Get-WindowsImage -ImagePath $wimPath -Index $idx.ImageIndex -ErrorAction Stop
            }
            $match = $images | Where-Object { $_.EditionId -eq $currentEdition -and $_.InstallationType -eq $currentInstallationType }
            if ($match) {
                Add-PreCheckResult -Name "ISO edition matches current OS ($currentEdition, $currentInstallationType)" -Result "PASS" -Detail "Matching edition+installation type found in media (Index $($match[0].ImageIndex): $($match[0].ImageName))."
                # Remember which index matched - Section 5 passes this to
                # setup.exe via /ImageIndex. Without it, Setup falls back to
                # its own auto-detection (SkuLib-based), which can fail
                # outright with /Quiet when install.wim has multiple
                # applicable images: MOSETUP_E_NO_MATCHING_INSTALL_IMAGE
                # (0xC1900215) - confirmed both via Microsoft's own "/ImageIndex"
                # docs and an actual setuperr.log hit on TestVM1 ("SelectImageIndex:
                # ... No SkuLib Upgrade edition available... Matching upgrade
                # edition not found in SkuLib").
                $script:MatchedImageIndex = $match[0].ImageIndex
                # Derive the target build number automatically from the media's own
                # Version string (e.g. "10.0.20348.1") so Update-UpgradeStatus.ps1 can
                # detect First Boot/OOBE without needing a manually maintained parameter.
                $verParts = $match[0].Version -split '\.'
                if ($verParts.Count -ge 3) {
                    Set-UpgradeRegistryValue -Name "TargetBuild" -Value $verParts[2]
                    Write-Log "Target build number derived from media: $($verParts[2])"
                }

                # Flash a clear, prominent "what's about to happen" banner now
                # that the ISO is mounted AND the edition match is confirmed -
                # both the source and target OS are now definitively known,
                # so this is the earliest honest point to display it (rather
                # than only quietly logging it later during baseline
                # recording in Section 4).
                try {
                    $sourceOsCaption = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption
                } catch {
                    $sourceOsCaption = "(current OS caption unavailable)"
                }
                $sourceBuildForBanner = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name CurrentBuildNumber -ErrorAction SilentlyContinue).CurrentBuildNumber
                $targetOsFriendly = $match[0].ImageName
                Set-UpgradeRegistryValue -Name "TargetOSCaption" -Value $targetOsFriendly
                Write-Log "===================================================================="
                Write-Log " UPGRADE PATH CONFIRMED"
                Write-Log "   Current OS : $sourceOsCaption (build $sourceBuildForBanner)"
                Write-Log "   Target OS  : $targetOsFriendly (build $($verParts[2]))"
                Write-Log "===================================================================="

                # BUG FOUND & FIXED (2026-08-26, real TestVM2 run): a same-
                # version repair-install (media build == currently installed
                # build) passed every existing check - edition/InstallationType
                # match is satisfied trivially when they're literally the same
                # OS - and setup.exe launched anyway, wasting ~40 min and
                # producing an ambiguous SourceBuild==TargetBuild run that later
                # broke phase detection (see Update-UpgradeStatus.ps1 fix).
                # Explicit customer decision: hard-block this instead, since
                # this tool is for genuine version upgrades, not repair-installs.
                if ($verParts.Count -ge 3) {
                    if ([int]$verParts[2] -le [int]$sourceBuildForBanner) {
                        Add-PreCheckResult -Name "Target media build is newer than current OS build" -Result "FAIL" -Detail "Media build ($($verParts[2])) is NOT newer than the currently installed build ($sourceBuildForBanner). This is not a genuine upgrade path (same-version repair-install, or older media). Use media for a newer Windows Server version."
                    } else {
                        Add-PreCheckResult -Name "Target media build is newer than current OS build" -Result "PASS" -Detail "Media build ($($verParts[2])) is newer than the currently installed build ($sourceBuildForBanner)."
                    }
                } else {
                    Add-PreCheckResult -Name "Target media build is newer than current OS build" -Result "WARN" -Detail "Could not parse the media's build number from '$($match[0].Version)' - verify manually that this media is for a NEWER OS version before relying on this run."
                }
            } else {
                # Distinguish "edition present but wrong Core/GUI flavor" (the
                # dangerous silent-downgrade case) from "edition missing entirely".
                $editionOnlyMatch = $images | Where-Object { $_.EditionId -eq $currentEdition }
                if ($editionOnlyMatch) {
                    $foundTypes = ($editionOnlyMatch.InstallationType -join ", ")
                    Add-PreCheckResult -Name "ISO edition matches current OS ($currentEdition, $currentInstallationType)" -Result "FAIL" -Detail "Edition '$currentEdition' exists on media but NOT as InstallationType '$currentInstallationType' (media only has: $foundTypes). Do not proceed with mismatched Core/Desktop-Experience media - it can silently change the GUI state of this server. Use media that has the matching installation type."
                } else {
                    $available = (($images | ForEach-Object { "$($_.EditionId) [$($_.InstallationType)]" }) -join ", ")
                    Add-PreCheckResult -Name "ISO edition matches current OS ($currentEdition, $currentInstallationType)" -Result "FAIL" -Detail "Current edition '$currentEdition' not present on this media. Available editions: $available."
                }
                Add-PreCheckResult -Name "Target media build is newer than current OS build" -Result "WARN" -Detail "Not evaluated - no matching image found on media (see the edition-match failure above)."
            }
        }
    } catch {
        Add-PreCheckResult -Name "ISO edition matches current OS" -Result "WARN" -Detail "Could not verify edition match ($_) - proceeding, verify manually before relying on this run."
        Add-PreCheckResult -Name "Target media build is newer than current OS build" -Result "WARN" -Detail "Could not verify (edition-match check itself failed: $_) - verify manually that this media is for a NEWER OS version before relying on this run."
    }
}

# --- 2.7 Licensing / activation health ---------------------------------------
# Deliberately NON-BLOCKING (WARN, not FAIL): an unlicensed/unactivated OS is
# a licensing/compliance concern, not a technical blocker to the upgrade
# itself succeeding - hard-stopping here would prevent an upgrade that would
# otherwise complete fine. The pre-upgrade state is recorded so the final
# summary can always show an explicit activation recommendation either way
# (see Invoke-PostUpgradeValidation in Update-UpgradeStatus.ps1).
try {
    $lic = Get-CimInstance SoftwareLicensingProduct -ErrorAction SilentlyContinue |
        Where-Object { $_.PartialProductKey -and $_.ApplicationId -eq "55c92734-d682-4d71-983e-d6ec3f16059f" }
    $licensed = $lic | Where-Object { $_.LicenseStatus -eq 1 }
    if ($licensed) {
        Add-PreCheckResult -Name "OS activation / licensing healthy" -Result "PASS" -Detail "LicenseStatus=Licensed."
        Set-UpgradeRegistryValue -Name "PreUpgradeLicenseStatus" -Value "Licensed"
    } else {
        $statusText = if ($lic) { ($lic | Select-Object -First 1 -ExpandProperty LicenseStatus) } else { "Unknown" }
        Add-PreCheckResult -Name "OS activation / licensing healthy" -Result "WARN" -Detail "LicenseStatus=$statusText (expected Licensed) - proceeding anyway (non-blocking); activation will be re-checked and called out in the final post-upgrade summary."
        Set-UpgradeRegistryValue -Name "PreUpgradeLicenseStatus" -Value "NotLicensed"
    }
} catch {
    Add-PreCheckResult -Name "OS activation / licensing healthy" -Result "WARN" -Detail "Could not query licensing state: $_ - proceeding anyway (non-blocking)."
    Set-UpgradeRegistryValue -Name "PreUpgradeLicenseStatus" -Value "Unknown"
}

# =============================================================================
# SECTION 2b - WARN-AND-TERMINATE / WARN-ONLY CHECKS (customer addendum)
# =============================================================================

# --- Patch level currency -----------------------------------------------------
# Primary method: Windows Update Agent search for not-installed, non-hidden
# updates. Falls back to "days since last hotfix" if the WUA COM search itself
# cannot run (service disabled, no connectivity to an update source, etc).
try {
    $patchCurrent = $true
    $patchDetail  = ""
    $wuaJob = $null
    try {
        # Microsoft.Update.Session's Search() call has NO built-in timeout and
        # can hang for a very long time (10-20+ minutes observed in practice)
        # on a server with no route to an update source (no internet/WSUS) -
        # it exhausts its own internal retries against Microsoft Update
        # endpoints before ever throwing. Wrapped in a background job with a
        # hard 60-second timeout (same Start-Job/Wait-Job pattern already used
        # elsewhere in this solution) so a disconnected/restricted server
        # falls through to the Get-HotFix fallback quickly instead of
        # stalling the entire pre-check phase indefinitely.
        $wuaJob = Start-Job -ScriptBlock {
            $updateSession  = New-Object -ComObject Microsoft.Update.Session
            $updateSearcher = $updateSession.CreateUpdateSearcher()
            $searchResult   = $updateSearcher.Search("IsInstalled=0 and IsHidden=0")
            $searchResult.Updates.Count
        }
        if (Wait-Job -Job $wuaJob -Timeout 60) {
            $pendingCount = Receive-Job -Job $wuaJob -ErrorAction Stop
            if ($pendingCount -gt 0) {
                $patchCurrent = $false
                $patchDetail  = "$pendingCount pending update(s) not installed."
            } else {
                $patchDetail = "No pending updates found via Windows Update Agent search."
            }
        } else {
            throw "WUA search did not complete within 60 seconds (likely no route to an update source) - falling back to last-hotfix-age heuristic."
        }
    } catch {
        # Fallback heuristic: flag if the most recent hotfix is older than $MaxPatchAgeDays.
        Write-Log "WUA search unavailable ($_) - falling back to last-hotfix-age heuristic." "WARN"
        $lastHotfix = Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($lastHotfix -and $lastHotfix.InstalledOn) {
            $ageDays = (New-TimeSpan -Start $lastHotfix.InstalledOn -End (Get-Date)).Days
            if ($ageDays -gt $MaxPatchAgeDays) {
                $patchCurrent = $false
                $patchDetail  = "Last installed hotfix ($($lastHotfix.HotFixID)) is $ageDays days old (threshold $MaxPatchAgeDays)."
            } else {
                $patchDetail = "Last installed hotfix is $ageDays days old (within $MaxPatchAgeDays-day threshold)."
            }
        } else {
            $patchDetail = "Could not determine patch currency via WUA or Get-HotFix - proceeding with a warning."
        }
    } finally {
        if ($wuaJob) { Stop-Job -Job $wuaJob -ErrorAction SilentlyContinue | Out-Null; Remove-Job -Job $wuaJob -Force -ErrorAction SilentlyContinue }
    }

    if (-not $patchCurrent) {
        if ($SkipPatchCheckLab) {
            Add-PreCheckResult -Name "Patch level up-to-date" -Result "WARN" -Detail "$patchDetail (LAB OVERRIDE -SkipPatchCheckLab in effect - proceeding anyway. DO NOT use this override in production.)"
        } else {
            Add-PreCheckResult -Name "Patch level up-to-date" -Result "FAIL" -Detail "$patchDetail Re-run with -SkipPatchCheckLab only for lab/non-production validation."
        }
    } else {
        Add-PreCheckResult -Name "Patch level up-to-date" -Result "PASS" -Detail $patchDetail
    }
} catch {
    Add-PreCheckResult -Name "Patch level up-to-date" -Result "WARN" -Detail "Patch-level check itself failed unexpectedly: $_ - proceeding with a warning."
}

# --- VMware Tools currency (VMware VMs only; Hyper-V/physical are skipped) ---
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.Manufacturer -match "VMware") {
        $vmToolsKey = "HKLM:\SOFTWARE\VMware, Inc.\VMware Tools"
        $installed  = Test-Path $vmToolsKey
        $toolsOk    = $false
        $verFound   = $null
        if ($installed) {
            $installPath = (Get-ItemProperty $vmToolsKey -ErrorAction SilentlyContinue).InstallPath
            $toolboxCmd  = Join-Path $installPath "VMwareToolboxCmd.exe"
            if (Test-Path $toolboxCmd) {
                $rawVer = & $toolboxCmd -v 2>$null
                if ($rawVer -match '(\d+\.\d+\.\d+)') {
                    $verFound = [version]$Matches[1]
                    $toolsOk  = ($verFound -ge [version]$MinVMwareToolsVersion)
                }
            }
            $svc = Get-Service -Name "VMTools" -ErrorAction SilentlyContinue
            if (-not $svc -or $svc.Status -ne "Running") { $toolsOk = $false }
        }

        if ($toolsOk) {
            Add-PreCheckResult -Name "VMware Tools up-to-date (VMware VM detected)" -Result "PASS" -Detail "Version $verFound (>= $MinVMwareToolsVersion), service running."
        } else {
            Add-PreCheckResult -Name "VMware Tools up-to-date (VMware VM detected)" -Result "FAIL" -Detail "VMware Tools missing, not running, or below required version $MinVMwareToolsVersion (found: $verFound). Update VMware Tools before upgrading."
        }
    } elseif ($cs.Manufacturer -match "Microsoft Corporation" -and $cs.Model -match "Virtual Machine") {
        Add-PreCheckResult -Name "VMware Tools check" -Result "PASS" -Detail "Hyper-V VM detected - VMware Tools check not applicable, continuing."
    } else {
        Add-PreCheckResult -Name "VMware Tools check" -Result "PASS" -Detail "Not a VMware VM (Manufacturer='$($cs.Manufacturer)') - check not applicable."
    }
} catch {
    Add-PreCheckResult -Name "VMware Tools check" -Result "WARN" -Detail "Could not evaluate hypervisor/VMware Tools state: $_ - proceeding with a warning."
}

# --- RDS Session Host -> CAL license server pointer (warning-only) ------------
# Enhanced 2026-08-26 (customer ask). Per Microsoft's documented RDS CAL
# version-compatibility rules (learn.microsoft.com/windows-server/remote/
# remote-desktop-services/rds-client-access-license): a license server can
# only install/issue CALs for its OWN Windows Server version or an EARLIER
# one - never a later one. So once this session host is upgraded, its
# configured CAL license server(s) must (a) run an OS version >= the TARGET
# OS being upgraded to, AND (b) already have CALs for that target OS version
# installed - otherwise clients lose the ability to obtain a valid RDS CAL
# once the post-upgrade licensing grace period ends. Best-effort remote
# check, bounded by a timeout (same Start-Job/Wait-Job pattern as the WUA
# search above) so an unreachable/firewalled license server can never stall
# this pre-check phase - always WARN, never FAIL, since this is a licensing/
# compliance concern (same category as the OS activation check) and the
# remote query itself may not always be possible (no network path, no WMI/
# DCOM access, etc).
try {
    $rdsFeature = $null
    try { $rdsFeature = Get-WindowsFeature -Name RDS-RD-Server -ErrorAction SilentlyContinue } catch {}
    if ($rdsFeature -and $rdsFeature.Installed) {
        $licServers      = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\Licensing Core" -Name "LicenseServers" -ErrorAction SilentlyContinue).LicenseServers
        $targetOsCaption = Get-UpgradeRegistryValue -Name "TargetOSCaption" -Default $null
        $targetBuild     = Get-UpgradeRegistryValue -Name "TargetBuild" -Default $null
        $targetDesc      = if ($targetOsCaption) { $targetOsCaption } else { "the target OS this server is being upgraded to" }

        if (-not $licServers) {
            Add-PreCheckResult -Name "RDS Session Host CAL license server check" -Result "WARN" `
                -Detail "RD Session Host role is installed but no CAL license server is configured (LicenseServers is empty under HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\Licensing Core). Configure one and ensure it meets the version requirements below before relying on RDS after this upgrade."
        } else {
            $serverFindings = foreach ($ls in $licServers) {
                $lsName = ($ls -split ':')[0]   # LicenseServers entries can carry an optional ":port" suffix
                $job = $null
                try {
                    $job = Start-Job -ScriptBlock { param($ComputerName) Get-CimInstance Win32_OperatingSystem -ComputerName $ComputerName -ErrorAction Stop | Select-Object Caption, BuildNumber } -ArgumentList $lsName
                    if (Wait-Job -Job $job -Timeout 15) {
                        $remoteOs = Receive-Job -Job $job -ErrorAction Stop
                        if ($targetBuild -and $remoteOs.BuildNumber) {
                            if ([int]$remoteOs.BuildNumber -lt [int]$targetBuild) {
                                "INCOMPATIBLE: '$lsName' runs $($remoteOs.Caption) (build $($remoteOs.BuildNumber)), OLDER than $targetDesc (build $targetBuild) - it CANNOT issue CALs for the upgraded OS until it is itself upgraded to $targetDesc or later."
                            } else {
                                "OK: '$lsName' runs $($remoteOs.Caption) (build $($remoteOs.BuildNumber)), same or newer than $targetDesc - confirm CALs for $targetDesc are actually installed/activated there."
                            }
                        } else {
                            "'$lsName' responded ($($remoteOs.Caption), build $($remoteOs.BuildNumber)) but the target OS build could not be determined for comparison - verify manually."
                        }
                    } else {
                        "'$lsName' did not respond within 15s (unreachable, firewalled, or WMI/DCOM blocked) - verify its OS version and installed CALs manually."
                    }
                } catch {
                    "'$lsName' could not be queried remotely ($_) - verify its OS version and installed CALs manually."
                } finally {
                    if ($job) { Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null; Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
                }
            }
            Add-PreCheckResult -Name "RDS Session Host CAL license server check" -Result "WARN" `
                -Detail "RD Session Host role is installed; configured CAL license server(s): $($licServers -join ', '). Requirement: each license server must run an OS version >= $targetDesc AND must already have CALs for $targetDesc installed/activated, or clients will be unable to obtain a valid RDS CAL once the post-upgrade licensing grace period ends. Findings: $($serverFindings -join ' | ') Reference: https://learn.microsoft.com/windows-server/remote/remote-desktop-services/rds-client-access-license"
        }
    } else {
        Add-PreCheckResult -Name "RDS Session Host CAL license server check" -Result "PASS" `
            -Detail "RD Session Host role is not installed; the CAL license server check is not applicable."
    }
} catch {
    Add-PreCheckResult -Name "RDS Session Host CAL license server check" -Result "WARN" -Detail "Could not evaluate RDS Session Host role: $_"
}

# --- Orphaned local user profiles (warning-only) ------------------------------
# "Orphaned" here means a profile registry entry under ProfileList whose SID
# no longer resolves to any account (local or domain) - typically left behind
# after a domain/local user account was deleted without also cleaning up
# their local profile via the supported "Delete" button in System Properties
# > Advanced > User Profiles. Harmless to an in-place upgrade technically,
# but worth flagging as hygiene, and customer-requested as an explicit check.
# Deliberately NEVER auto-remediated here - only detected/counted/reported,
# with a REVIEW-FIRST cleanup script printed for a human to run at their own
# discretion (removing profile registry data is not something to automate
# unattended inside a pre-check).
try {
    $profileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
    $orphanedProfiles = New-Object System.Collections.Generic.List[object]
    Get-ChildItem -Path $profileListPath -ErrorAction SilentlyContinue | ForEach-Object {
        $sidString = $_.PSChildName
        # Only evaluate real user-account SIDs (domain or local, both start
        # S-1-5-21-...) - built-in/service SIDs (SYSTEM, LOCAL SERVICE,
        # NETWORK SERVICE, well-known groups, etc.) always resolve and aren't
        # what "orphaned account" means here; skip them entirely rather than
        # risk a false positive.
        if ($sidString -notmatch '^S-1-5-21-') { return }
        $profilePath = (Get-ItemProperty -Path $_.PSPath -Name "ProfileImagePath" -ErrorAction SilentlyContinue).ProfileImagePath
        try {
            $sidObj = New-Object System.Security.Principal.SecurityIdentifier($sidString)
            $null = $sidObj.Translate([System.Security.Principal.NTAccount])
            # Resolved successfully to a live account - NOT orphaned.
        } catch {
            $orphanedProfiles.Add([pscustomobject]@{ Sid = $sidString; ProfilePath = $(if ($profilePath) { $profilePath } else { "(unknown)" }) })
        }
    }
    if ($orphanedProfiles.Count -eq 0) {
        Add-PreCheckResult -Name "Orphaned local user profiles" -Result "PASS" -Detail "No orphaned profile SIDs found under ProfileList."
    } else {
        $summaryText = ($orphanedProfiles | ForEach-Object { "$($_.Sid) [$($_.ProfilePath)]" }) -join "; "
        # HARD-BLOCKING (2026-07-26, explicit customer decision - see the
        # 2026-07-24 WARN-only design and the follow-up clarification
        # confirming this should actually stop the upgrade, not just warn):
        # unlike most other checks in this solution, orphaned profiles are
        # now a genuine gate - the upgrade does NOT proceed this run. The
        # cleanup script printed below is still never auto-executed (only a
        # human decides what's safe to remove) - the admin must run it (or
        # otherwise resolve the orphaned accounts) and then re-initiate the
        # upgrade from scratch; this check will PASS on the next attempt
        # once ProfileList no longer has any unresolved S-1-5-21-* entries.
        Add-PreCheckResult -Name "Orphaned local user profiles" -Result "FAIL" -Detail "$($orphanedProfiles.Count) orphaned profile SID(s) found (registry entry exists but the owning account no longer resolves - typically a deleted user whose local profile was never cleaned up): $summaryText. BLOCKING - clean these up (see the cleanup options printed below) then re-initiate the upgrade."
        Set-UpgradeRegistryValue -Name "OrphanedProfileCount" -Value $orphanedProfiles.Count -Type DWord

        # A ready-to-run cleanup script is GENERATED (never auto-executed) next
        # to this script in the staging folder, so the admin has a third,
        # zero-copy-paste option alongside the printed per-SID commands and the
        # printed bulk script.
        $orphanScriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { "C:\Temp\OSUpgradeStaging" }
        $orphanScriptPath = Join-Path $orphanScriptDir "Remove-OrphanedProfiles.ps1"
        $orphanScriptWritten = $false
        try {
            if (-not (Test-Path $orphanScriptDir)) { New-Item -ItemType Directory -Path $orphanScriptDir -Force | Out-Null }
            $orphanCleanupScriptBody = @'
<#
.SYNOPSIS
    Removes orphaned local user profile registry entries so the OS upgrade
    pre-check "Orphaned local user profiles" can pass.

.DESCRIPTION
    GENERATED automatically by Start-TargetUpgrade.ps1 when its pre-upgrade
    assessment found orphaned profiles on this server. It was written to
    disk but deliberately NOT executed - removing profile data is a human
    decision, never something a pre-check should do unattended.

    "Orphaned" = a SID under
    HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList that no
    longer resolves to any account (local or domain) - typically left behind
    when a user account was deleted without also removing its local profile
    via System Properties > Advanced > User Profiles > Delete.

    This script is SELF-DISCOVERING: it re-scans ProfileList at run time and
    removes WHATEVER is orphaned at that moment, so the same file keeps
    working unchanged if different/new orphaned accounts appear later. No
    SIDs are hardcoded.

    Two separate things can be removed, each confirmed independently:
      1. The ProfileList REGISTRY entries (and their .bak counterparts).
         This alone is what clears the "Account Unknown" rows from
         System Properties > Advanced > User Profiles > Settings and lets
         the upgrade pre-check pass.
      2. OPTIONALLY, the profile FOLDERS on disk (e.g. C:\Users\sam). This
         deletes REAL USER DATA and cannot be undone, so it is a second,
         explicit opt-in - answered separately, defaulting to NO.

.PARAMETER Force
    Skip the interactive confirmation prompt. Intended for a reviewed,
    deliberate unattended run - not the default. On its own, -Force still
    removes ONLY the registry entries.

.PARAMETER IncludeProfileFolder
    Also delete each orphaned profile's folder on disk. Interactively you
    are asked about this anyway; pass this switch to answer "yes" up front
    (required to delete folders during a -Force run, which never prompts).

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Remove-OrphanedProfiles.ps1

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Remove-OrphanedProfiles.ps1 -Force

.EXAMPLE
    Unattended, registry entries AND profile folders:
    powershell.exe -ExecutionPolicy Bypass -File .\Remove-OrphanedProfiles.ps1 -Force -IncludeProfileFolder
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$IncludeProfileFolder
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "This script must be run from an ELEVATED PowerShell session (Run as Administrator)."
}

function Confirm-YesNo {
    param([string]$Prompt)
    $answer = Read-Host $Prompt
    return ("$answer".Trim() -match '^(y|yes)$')
}

function Get-FolderSizeMB {
    param([string]$Path)
    try {
        $bytes = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                  Measure-Object -Property Length -Sum).Sum
        if (-not $bytes) { return 0 }
        return [math]::Round($bytes / 1MB, 1)
    } catch { return $null }
}

function Test-SafeProfileFolder {
    <#
    Guard rail for the folder-deletion path. ProfileImagePath is attacker-
    irrelevant here but IS operator-supplied data that has been wrong before
    (blank, truncated, or pointing somewhere shared), and a bad value passed
    to Remove-Item -Recurse -Force is unrecoverable - so refuse anything that
    is not clearly an individual profile directory.
    #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }

    $full = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\')

    # Never a drive root (e.g. "C:\").
    if ($full -match '^[A-Za-z]:$') { return $false }

    $blocked = @(
        $env:SystemRoot,
        $env:ProgramData,
        ${env:ProgramFiles},
        ${env:ProgramFiles(x86)},
        (Join-Path $env:SystemDrive 'Users'),
        $env:USERPROFILE,
        (Join-Path (Join-Path $env:SystemDrive 'Users') 'Public'),
        (Join-Path (Join-Path $env:SystemDrive 'Users') 'Default'),
        (Join-Path (Join-Path $env:SystemDrive 'Users') 'Default User'),
        (Join-Path (Join-Path $env:SystemDrive 'Users') 'All Users')
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }

    foreach ($b in $blocked) {
        # Equal to, or an ANCESTOR of, anything protected.
        if ($full -ieq $b) { return $false }
        if ($b.StartsWith($full + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Invoke-NativeQuiet {
    <#
    Runs a console tool, discarding its output and returning the exit code.
    The $ErrorActionPreference dance is essential, not cosmetic: this script
    runs with 'Stop', under which ANY native command writing to stderr raises
    a terminating NativeCommandError. takeown/icacls routinely write to
    stderr for individual files while still succeeding overall, so without
    this the whole cleanup would abort partway through.
    #>
    param([string]$FilePath, [string[]]$ArgumentList)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @ArgumentList 2>&1 | Out-Null
        return $LASTEXITCODE
    } catch {
        return -1
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Remove-ProfileFolder {
    <#
    Deletes one orphaned profile folder in escalating stages, doing the least
    invasive thing that works. Only ever called on a path that already passed
    Test-SafeProfileFolder.

    Stage 1 - Remove-Item. Fails on the legacy compatibility JUNCTIONS inside
      AppData ('Application Data', 'Local Settings', ...) because it walks
      INTO them and hits their by-design deny ACE:
      "Access to the path ...\AppData\Local\Application Data is denied".
    Stage 2 - cmd's 'rd /s /q', which deletes a reparse point as a LINK
      instead of following it, and removes read-only files without asking.
      This alone fixes the junction case - no permission changes needed.
    Stage 3 - only if still present: take ownership and reset the ACLs, then
      'rd' again. 'icacls /reset' matters here because a profile owned by a
      deleted SID can carry explicit DENY entries, and /grant cannot override
      a deny - it has to be cleared.

    Escalation is deliberately LAST: 'takeown /R' and 'icacls /T' traverse
    directory junctions, so on a profile containing a junction that points
    outside itself they could rewrite ownership/permissions on unrelated
    data. Stage 2 removes those junctions first, so by the time stage 3 runs
    there is normally nothing left to traverse out of.
    #>
    param([string]$Path)

    $firstError = $null
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        $firstError = $_.Exception.Message
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Success = $true; Method = 'direct delete'; Error = $null }
    }

    Invoke-NativeQuiet -FilePath 'cmd.exe' -ArgumentList @('/c', 'rd', '/s', '/q', $Path) | Out-Null
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Success = $true; Method = 'rd /s /q (junction-safe)'; Error = $null }
    }

    Write-Host ("   Delete blocked ({0})" -f $firstError) -ForegroundColor DarkYellow
    Write-Host ("   Taking ownership and resetting permissions on {0} ..." -f $Path) -ForegroundColor Yellow

    # *S-1-5-32-544 is the built-in Administrators SID - used instead of the
    # group NAME so this still works on non-English Windows.
    Invoke-NativeQuiet -FilePath 'takeown.exe' -ArgumentList @('/F', $Path, '/R', '/A', '/D', 'Y')                           | Out-Null
    Invoke-NativeQuiet -FilePath 'icacls.exe'  -ArgumentList @($Path, '/reset', '/T', '/C', '/Q')                            | Out-Null
    Invoke-NativeQuiet -FilePath 'icacls.exe'  -ArgumentList @($Path, '/grant', '*S-1-5-32-544:(OI)(CI)F', '/T', '/C', '/Q') | Out-Null
    Invoke-NativeQuiet -FilePath 'attrib.exe'  -ArgumentList @('-R', '-S', '-H', "$Path\*", '/S', '/D')                      | Out-Null

    Invoke-NativeQuiet -FilePath 'cmd.exe' -ArgumentList @('/c', 'rd', '/s', '/q', $Path) | Out-Null
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Success = $true; Method = 'takeown + icacls reset + rd'; Error = $null }
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        $firstError = $_.Exception.Message
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Success = $true; Method = 'takeown + icacls reset + Remove-Item'; Error = $null }
    }

    return [pscustomobject]@{ Success = $false; Method = 'all methods failed'; Error = $firstError }
}

$profileListPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

# Matches the detection logic in Start-TargetUpgrade.ps1 exactly: only real
# user-account SIDs (S-1-5-21-*), so built-in/service SIDs are never touched.
# @(...) is required: with exactly ONE orphan the pipeline returns a bare
# PSCustomObject whose .Count is $null, which blanked every "N of M" message
# and made the final "$removed -eq $orphans.Count" success test fail.
$orphans = @(Get-ChildItem -Path $profileListPath -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^S-1-5-21-' } |
    ForEach-Object {
        $sid = $_.PSChildName
        $resolved = $true
        try {
            $null = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount])
        } catch { $resolved = $false }
        if (-not $resolved) {
            [pscustomobject]@{
                Sid         = $sid
                PSPath      = $_.PSPath
                ProfilePath = (Get-ItemProperty -Path $_.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
            }
        }
    })

if (-not $orphans) {
    Write-Host "No orphaned profile SIDs found under ProfileList - nothing to do." -ForegroundColor Green
    Write-Host "The 'Orphaned local user profiles' pre-check will pass; re-run the OS upgrade." -ForegroundColor Cyan
    return
}

Write-Host ""
Write-Host "The following $($orphans.Count) orphaned ProfileList registry entr(ies) will be REMOVED:" -ForegroundColor Yellow
foreach ($o in $orphans) {
    $shown = if ($o.ProfilePath) { $o.ProfilePath } else { '(unknown)' }
    $sizeText = ''
    if ($o.ProfilePath -and (Test-Path -LiteralPath $o.ProfilePath -PathType Container)) {
        $mb = Get-FolderSizeMB -Path $o.ProfilePath
        if ($null -ne $mb) { $sizeText = "  [$mb MB on disk]" }
    } elseif ($o.ProfilePath) {
        $sizeText = '  [folder no longer present]'
    }
    Write-Host ("   {0}    profile folder: {1}{2}" -f $o.Sid, $shown, $sizeText)
}
Write-Host ""
Write-Host "Removing the registry entries clears these from System Properties > Advanced >" -ForegroundColor Yellow
Write-Host "User Profiles (where they show as 'Account Unknown') and lets the upgrade" -ForegroundColor Yellow
Write-Host "pre-check pass. The profile FOLDERS above are a separate question, asked next." -ForegroundColor Yellow
Write-Host ""

$deleteFolders = [bool]$IncludeProfileFolder

if (-not $Force) {
    if (-not (Confirm-YesNo "Proceed with removing the registry entries? Type Y or YES to confirm, anything else to abort")) {
        Write-Host "Aborted - nothing was changed." -ForegroundColor Yellow
        return
    }
    if (-not $deleteFolders) {
        Write-Host ""
        Write-Host "Also delete the profile FOLDERS listed above from disk?" -ForegroundColor Red
        Write-Host "This permanently deletes REAL USER DATA (documents, desktop, profile" -ForegroundColor Red
        Write-Host "settings) and CANNOT BE UNDONE. Answer N to keep the folders - the" -ForegroundColor Red
        Write-Host "upgrade pre-check passes either way." -ForegroundColor Red
        $deleteFolders = Confirm-YesNo "Delete the profile folders too? Type Y or YES to confirm, anything else to keep them"
    }
}

if ($deleteFolders) {
    Write-Host ""
    Write-Host "Profile folders WILL be deleted along with the registry entries." -ForegroundColor Red
} else {
    Write-Host ""
    Write-Host "Profile folders will be KEPT on disk (registry entries only)." -ForegroundColor Cyan
}
Write-Host ""

$removed       = 0
$foldersOk     = 0
$foldersFailed = @()

foreach ($o in $orphans) {
    $shown = if ($o.ProfilePath) { $o.ProfilePath } else { '(unknown)' }

    # Folder first: if it fails, the registry entry is still removed below so
    # the upgrade is unblocked either way, and the leftover path is reported.
    if ($deleteFolders -and $o.ProfilePath) {
        if (Test-SafeProfileFolder -Path $o.ProfilePath) {
            $fr = Remove-ProfileFolder -Path $o.ProfilePath
            if ($fr.Success) {
                Write-Host ("Deleted profile folder: {0}  [{1}]" -f $o.ProfilePath, $fr.Method) -ForegroundColor Green
                $foldersOk++
            } else {
                Write-Host ("FAILED to delete profile folder {0} even after taking ownership: {1}" -f $o.ProfilePath, $fr.Error) -ForegroundColor Red
                Write-Host "   A file there is most likely still open/locked by a running process." -ForegroundColor Red
                $foldersFailed += $o.ProfilePath
            }
        } elseif (Test-Path -LiteralPath $o.ProfilePath) {
            Write-Host ("SKIPPED folder '{0}' - not a safe individual profile directory (system/shared/root path). Delete it manually if it really is unwanted." -f $o.ProfilePath) -ForegroundColor Yellow
            $foldersFailed += $o.ProfilePath
        } else {
            Write-Host ("Profile folder '{0}' does not exist - nothing to delete." -f $o.ProfilePath) -ForegroundColor DarkGray
        }
    }

    try {
        Remove-Item -Path $o.PSPath -Recurse -Force
        $bak = $o.PSPath + '.bak'
        if (Test-Path $bak) { Remove-Item -Path $bak -Recurse -Force }
        Write-Host ("Removed orphaned ProfileList entry: {0} (was: {1})" -f $o.Sid, $shown) -ForegroundColor Green
        $removed++
    } catch {
        Write-Host ("FAILED to remove {0}: {1}" -f $o.Sid, $_) -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "$removed of $($orphans.Count) orphaned ProfileList entr(ies) removed." -ForegroundColor Green
if ($deleteFolders) {
    Write-Host "$foldersOk profile folder(s) deleted from disk." -ForegroundColor Green
    if ($foldersFailed.Count -gt 0) {
        Write-Host "The following folder(s) were NOT deleted and remain on disk - remove them manually if intended:" -ForegroundColor Yellow
        $foldersFailed | ForEach-Object { Write-Host ("   " + $_) -ForegroundColor Yellow }
    }
} else {
    Write-Host "Profile folders were left on disk. Note the ProfileList entries are now gone," -ForegroundColor Cyan
    Write-Host "so the User Profiles dialog can no longer delete them - use Remove-Item if wanted." -ForegroundColor Cyan
}
if ($removed -eq $orphans.Count) {
    Write-Host "NEXT STEP: re-run the OS upgrade from Server A (same command as before) -" -ForegroundColor Cyan
    Write-Host "the 'Orphaned local user profiles' pre-check will now pass." -ForegroundColor Cyan
} else {
    Write-Host "Some entries could not be removed - resolve those before re-running the upgrade." -ForegroundColor Yellow
}
'@
            Set-Content -Path $orphanScriptPath -Value $orphanCleanupScriptBody -Encoding UTF8 -Force
            $orphanScriptWritten = $true
            Set-UpgradeRegistryValue -Name "OrphanCleanupScriptPath" -Value $orphanScriptPath
        } catch {
            Write-Log "Could not write the ready-to-run orphaned-profile cleanup script to $orphanScriptPath : $_ - the copy/paste options printed below are unaffected." "WARN"
        }

        $profileListRegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"

        Write-Log "===================================================================="
        Write-Log " ORPHANED LOCAL PROFILE(S) DETECTED: $($orphanedProfiles.Count) - MUST BE RESOLVED BEFORE THIS UPGRADE CAN PROCEED"
        Write-Log "===================================================================="
        Write-Log " Found now: $summaryText"
        Write-Log " This is BLOCKING - the upgrade will NOT proceed this run. Nothing"
        Write-Log " below is executed automatically; REVIEW first, and only clean up"
        Write-Log " profiles you have confirmed are genuinely no longer needed. Options 1"
        Write-Log " and 2 remove only the ProfileList registry entries; Option 3 removes"
        Write-Log " those and can OPTIONALLY delete the C:\Users\<name> folders too, but"
        Write-Log " only if you explicitly answer YES to its second prompt - deleting a"
        Write-Log " profile folder destroys real user data and cannot be undone."
        Write-Log " Choose ANY ONE of the three options below."
        Write-Log "--------------------------------------------------------------------"
        Write-Log " OPTION 1 - DELETE INDIVIDUAL ORPHANED ACCOUNTS"
        Write-Log " Run these in an ELEVATED PowerShell on $env:COMPUTERNAME. Use this"
        Write-Log " when you want to remove only SOME of the accounts listed above."
        Write-Log "--------------------------------------------------------------------"
        foreach ($o in $orphanedProfiles) {
            Write-Log ("# " + $o.Sid + "   (profile folder: " + $o.ProfilePath + ")")
            Write-Log ("Remove-Item -Path '" + $profileListRegPath + "\" + $o.Sid + "' -Recurse -Force")
            Write-Log ("Remove-Item -Path '" + $profileListRegPath + "\" + $o.Sid + ".bak' -Recurse -Force -ErrorAction SilentlyContinue")
        }
        Write-Log "--------------------------------------------------------------------"
        Write-Log " OPTION 2 - DELETE ALL ORPHANED ACCOUNTS AT ONCE"
        Write-Log " Copy/paste the whole block below into an ELEVATED PowerShell on"
        Write-Log " $env:COMPUTERNAME. It is SELF-DISCOVERING (no hardcoded SIDs) - it"
        Write-Log " re-scans ProfileList and removes WHATEVER is orphaned at the moment"
        Write-Log " you run it, so the same block keeps working unchanged for any future"
        Write-Log " orphaned accounts - one or a hundred, in one shot."
        Write-Log "--------------------------------------------------------------------"
        Write-Log "Get-ChildItem `"HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList`" -ErrorAction SilentlyContinue |"
        Write-Log "    Where-Object { `$_.PSChildName -match '^S-1-5-21-' } |"
        Write-Log "    ForEach-Object {"
        Write-Log "        `$sid = `$_.PSChildName"
        Write-Log "        `$resolved = `$true"
        Write-Log "        try {"
        Write-Log "            `$null = (New-Object System.Security.Principal.SecurityIdentifier(`$sid)).Translate([System.Security.Principal.NTAccount])"
        Write-Log "        } catch { `$resolved = `$false }"
        Write-Log "        if (-not `$resolved) {"
        Write-Log "            `$path = (Get-ItemProperty -Path `$_.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath"
        Write-Log "            Write-Host `"Removing orphaned ProfileList entry: `$sid (was: `$path)`""
        Write-Log "            Remove-Item -Path `$_.PSPath -Recurse -Force"
        Write-Log "            `$bak = `$_.PSPath + `".bak`""
        Write-Log "            if (Test-Path `$bak) { Remove-Item -Path `$bak -Recurse -Force }"
        Write-Log "        }"
        Write-Log "    }"
        Write-Log "--------------------------------------------------------------------"
        Write-Log " OPTION 3 - RUN THE READY-MADE SCRIPT ALREADY GENERATED ON THIS SERVER"
        Write-Log "--------------------------------------------------------------------"
        if ($orphanScriptWritten) {
            Write-Log " A ready-to-run cleanup script has been written to $env:COMPUTERNAME at:"
            Write-Log "   $orphanScriptPath"
            Write-Log " It does the same thing as Option 2 (self-discovering, removes ALL"
            Write-Log " orphaned accounts in one shot) but needs no copy/paste. It lists"
            Write-Log " exactly what it will remove (with folder sizes) and asks you to"
            Write-Log " confirm with Y or YES before changing anything. It then asks a"
            Write-Log " SECOND, separate question: whether to also delete the profile"
            Write-Log " FOLDERS from disk - answer N there to keep the user data (the"
            Write-Log " pre-check passes either way). Run it in an ELEVATED PowerShell:"
            Write-Log "--------------------------------------------------------------------"
            Write-Log ("powershell.exe -ExecutionPolicy Bypass -File `"" + $orphanScriptPath + "`"")
            Write-Log ""
            Write-Log " Add -Force only if you have already reviewed the list above and"
            Write-Log " want to skip the confirmation prompts (-Force alone removes ONLY"
            Write-Log " the registry entries; add -IncludeProfileFolder to delete the"
            Write-Log " profile folders too in the same unattended run):"
            Write-Log ("powershell.exe -ExecutionPolicy Bypass -File `"" + $orphanScriptPath + "`" -Force")
        } else {
            Write-Log " (Unavailable this run - the script could not be written to"
            Write-Log "  $orphanScriptPath, see the WARN above. Use Option 1 or 2 instead.)"
        }
        Write-Log "--------------------------------------------------------------------"
        Write-Log " AFTER CLEANING UP THE ORPHANED ACCOUNTS: RE-RUN THE OS UPGRADE"
        Write-Log "--------------------------------------------------------------------"
        Write-Log " Nothing has been changed on $env:COMPUTERNAME by this run (no backup,"
        Write-Log " no ISO mount, no setup.exe), so it is safe to simply retry once the"
        Write-Log " orphaned accounts are cleared. Re-run the SAME orchestrator command"
        Write-Log " from Server A - this check will then PASS and the upgrade will"
        Write-Log " proceed normally from there."
        Write-Log "--------------------------------------------------------------------"
        Write-Log "# OPTIONAL FOLLOW-UP (separate, manual, higher-risk step - NOT included"
        Write-Log "# in ANY of the three options above): once you have confirmed a profile"
        Write-Log "# FOLDER itself (see the ProfileImagePath listed per SID) is genuinely"
        Write-Log "# unneeded, you may also delete it manually, e.g.:"
        Write-Log "#   Remove-Item -Path 'C:\Users\<profile-folder-name>' -Recurse -Force"
        Write-Log "# BACK UP FIRST if there is any doubt - this deletes real user data and"
        Write-Log "# cannot be undone."
        Write-Log "===================================================================="
    }
} catch {
    # Deliberately stays WARN (not FAIL) even though a confirmed FINDING is
    # now blocking - a failure to even RUN the check (e.g. registry read
    # error) is uncertainty, not a confirmed orphaned-account problem, so it
    # shouldn't block the upgrade the same way an actual finding does.
    Add-PreCheckResult -Name "Orphaned local user profiles" -Result "WARN" -Detail "Could not evaluate orphaned profiles: $_ - proceeding anyway (non-blocking); this is a check-execution failure, not a confirmed orphaned-account finding."
}

# =============================================================================
# SECTION 2c - WRITE THE DEDICATED PRE-CHECK REPORT + EVALUATE THE GATE
# =============================================================================
try {
    if (-not (Test-Path (Split-Path $BackupRoot -Parent -ErrorAction SilentlyContinue))) {
        # Drive holding BackupRoot may not exist yet - handled below when we
        # actually create the backup folder; the pre-check report falls back
        # to the local ProgramData Logs folder if BackupRoot's drive is missing.
    }
    $preCheckReportDir = if (Test-Path (Split-Path $BackupRoot -Qualifier)) { $BackupRoot } else { $script:LogDir }
    if (-not (Test-Path $preCheckReportDir)) { New-Item -ItemType Directory -Path $preCheckReportDir -Force | Out-Null }
    $preCheckReportPath = Join-Path $preCheckReportDir "PreCheckReport_$($script:RunStamp).log"
    $preCheckLog | Out-File -FilePath $preCheckReportPath -Encoding UTF8
    Write-Log "Pre-check report written to $preCheckReportPath"
} catch {
    Write-Log "Could not write dedicated pre-check report (non-blocking): $_" "WARN"
}

if ($hardFailures.Count -gt 0) {
    $msg = ($hardFailures -join " | ")
    Set-Phase -Phase 1 -PhaseName "Pre-Upgrade Assessment" -Status "Failed" -PercentComplete 0 `
        -ProgressSource "PrecheckGate" -ProgressFreshness "Terminal" -Notes $msg
    Write-Log "PRE-CHECK GATE FAILED - terminating immediately. Details: $msg" "ERROR"
    throw "Pre-upgrade assessment failed: $msg"
}
Write-Log "All hard-fail pre-checks PASSED. Warnings (non-blocking): $($warnings.Count)"
foreach ($w in $warnings) { Write-Log "  - $w" "WARN" }

# =============================================================================
# SECTION 3 - STATE & POLICY BACKUP  (D:\UpgradeBackup by default)
# =============================================================================
# Backup starts at 0/8 local tasks, which maps to 10% overall. Each completed
# task below advances the local task-count value until Stage 2 reaches the
# 25% overall handoff boundary.
Set-Phase -Phase 2 -PhaseName "State & Policy Backup" -Status "InProgress" `
    -PercentComplete 0 -PercentSource "Measured" -ProgressSource "StageBoundary" -ProgressFreshness "Milestone"

# TASK-COUNT-BASED PERCENTAGE (2026-07-24, same reasoning as
# $totalPrecheckSteps above) - IMPORTANT: keep $totalBackupSteps in sync
# with the actual number of Update-BackupProgress calls below - currently 8:
# 1) Pre-upgrade services snapshot, 2) Registry hives backup, 3) Local GPO
# backup (robocopy), 4) LGPO.exe-based GPO backup (runs/counted regardless
# of whether LGPO.exe was actually found - "found and backed up" vs "not
# found, skipped" are both a completed unit of backup WORK), 5) secedit
# security policy export, 6) gpresult report, 7) RDS CAL license DB backup
# (counted regardless of whether this server actually is a CAL license
# server - "checked, not applicable" is still a completed check), 8) System
# state backup (wbadmin - installs the Windows-Server-Backup feature first
# if missing, counted regardless of pass/fail like every other task here).
$totalBackupSteps = 8
$script:backupStepsDone = 0
function Update-BackupProgress {
    param([string]$TaskName)
    $script:backupStepsDone++
    $pct = [math]::Min(100, [int](100.0 * $script:backupStepsDone / $totalBackupSteps))
    Set-Phase -Phase 2 -PhaseName "State & Policy Backup" -Status "InProgress" -PercentComplete $pct -PercentSource "Measured" -Notes "Task $script:backupStepsDone/$totalBackupSteps complete: $TaskName"
}

try {
    $driveRoot = Split-Path $BackupRoot -Qualifier
    if ($driveRoot -eq (Split-Path $env:SystemDrive -Qualifier)) {
        throw "BackupRoot '$BackupRoot' resolves to the system drive ($env:SystemDrive) - it MUST be on a different drive."
    }
    $backupFolder = Join-Path $BackupRoot $script:RunStamp
    New-Item -ItemType Directory -Path $backupFolder -Force | Out-Null
    Write-Log "Backup folder created: $backupFolder"
    # Recorded so Update-UpgradeStatus.ps1 (a separate process/run) can find
    # this same run's backup folder later - both to mirror the phase/percent
    # progress log into it (a durable second copy alongside D:\UpgradeBackup,
    # since C:\ProgramData logs get purged by Remove-UpgradeArtifacts.ps1
    # after -RetentionDays) and to compare pre/post-upgrade services state.
    Set-UpgradeRegistryValue -Name "BackupFolder" -Value $backupFolder

    # --- 3.0 Pre-upgrade services snapshot (for post-upgrade comparison) ---
    # Captured now, before anything changes, so Update-UpgradeStatus.ps1's
    # post-upgrade validation (Phase 7) can diff the running/start-type state
    # of every service against this baseline and flag "Requires attention"
    # instead of only spot-checking a small hardcoded list.
    try {
        $svcSnapshotPath = Join-Path $backupFolder "Services_PreUpgrade.csv"
        Get-Service | Select-Object Name, DisplayName, Status, StartType |
            Sort-Object Name | Export-Csv -Path $svcSnapshotPath -NoTypeInformation -Force
        Set-UpgradeRegistryValue -Name "PreUpgradeServicesSnapshot" -Value $svcSnapshotPath
        Write-Log "Pre-upgrade services snapshot captured: $svcSnapshotPath"
    } catch {
        Write-Log "Could not capture pre-upgrade services snapshot (non-blocking): $_" "WARN"
    }
    Update-BackupProgress -TaskName "Pre-upgrade services snapshot"

    # --- 3.1 Registry hives -----------------------------------------------
    $regBackupDir = Join-Path $backupFolder "Registry"
    New-Item -ItemType Directory -Path $regBackupDir -Force | Out-Null

    # Enable SeBackupPrivilege for this session BEFORE saving the hives.
    # IMPORTANT (verified empirically): 'reg.exe EXPORT' does NOT consult
    # SeBackupPrivilege at all - it just walks the key via normal ACL-checked
    # reads and serializes to its own proprietary container format, so it can
    # only ever succeed on keys the caller already has ordinary read access
    # to (which HKLM\SECURITY denies to everyone except SYSTEM, by design -
    # enabling the privilege would NOT have fixed that). 'reg.exe SAVE',
    # however, calls the Win32 RegSaveKeyEx API, which explicitly REQUIRES
    # SeBackupPrivilege to bypass the target key's ACL and produces a real,
    # standard hive file (the same format as the live files under
    # %windir%\System32\config\) - restorable via 'reg.exe restore' or by
    # loading/replacing the hive offline (e.g. from WinRE), which is also a
    # more robust disaster-recovery format than export's own container
    # (restorable only via 'reg.exe import'). This is why we use SAVE below,
    # not EXPORT, despite EXPORT being the more commonly seen example online.
    if (Enable-BackupPrivilege) {
        Write-Log "SeBackupPrivilege enabled for this session - SAM/SECURITY hive save should now succeed."
    } else {
        Write-Log "Could not enable SeBackupPrivilege (non-blocking) - SAM/SECURITY hive save may fail with Access Denied; this is expected Windows behavior without it, even for a local Administrator." "WARN"
    }

    foreach ($hive in @("HKLM\SYSTEM","HKLM\SOFTWARE","HKLM\SAM","HKLM\SECURITY")) {
        $destFile = Join-Path $regBackupDir ("{0}.hiv" -f ($hive -replace '\\','_'))
        try {
            & reg.exe save $hive $destFile /y 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Registry hive saved: $hive -> $destFile"
            } else {
                Write-Log "Registry hive save returned exit code $LASTEXITCODE for $hive (SAM/SECURITY require SeBackupPrivilege to be enabled - non-blocking)." "WARN"
            }
        } catch {
            Write-Log "Registry hive save failed for $hive (non-blocking): $_" "WARN"
        }
    }
    Update-BackupProgress -TaskName "Registry hives backup"

    # --- 3.2 Local GPO + Security Policy (secedit) -------------------------
    $gpoBackupDir = Join-Path $backupFolder "GPO"
    New-Item -ItemType Directory -Path $gpoBackupDir -Force | Out-Null
    try {
        robocopy "C:\Windows\System32\GroupPolicy" (Join-Path $gpoBackupDir "GroupPolicy") /MIR /R:1 /W:1 /NFL /NDL /NJH | Out-Null
        robocopy "C:\Windows\System32\GroupPolicyUsers" (Join-Path $gpoBackupDir "GroupPolicyUsers") /MIR /R:1 /W:1 /NFL /NDL /NJH | Out-Null
        Write-Log "Local Group Policy folders backed up to $gpoBackupDir"
        $gptIni = Get-ChildItem -Path (Join-Path $gpoBackupDir "GroupPolicy") -Filter "gpt.ini" -Recurse -ErrorAction SilentlyContinue
        if (-not $gptIni) {
            Write-Log "C:\Windows\System32\GroupPolicy contains no gpt.ini - this machine currently has no Local GPO configured, so an EMPTY GroupPolicy backup folder is expected/correct here (nothing to back up), not a failure." "WARN"
        }
    } catch {
        Write-Log "Local GPO backup failed (non-blocking): $_" "WARN"
    }
    Update-BackupProgress -TaskName "Local GPO backup (robocopy)"

    # --- 3.2b LGPO.exe-based Local GPO backup (preferred, if available) ----
    # LGPO.exe (Microsoft Security Compliance Toolkit) exports the Local GPO
    # into a real, portable backup format (restorable via "LGPO.exe /g") and
    # additionally parses registry.pol into a human-readable .txt report -
    # more useful than the raw robocopy above, which only mirrors whatever is
    # (or isn't) already in the local GroupPolicy folder. Optional: only runs
    # if LGPO.exe was staged next to this script; otherwise skipped, non-blocking.
    $lgpoExe = Join-Path $PSScriptRoot "LGPO.exe"
    if (Test-Path $lgpoExe) {
        # Defensive: if LGPO.exe still carries a "Mark of the Web" (Zone.Identifier
        # NTFS alternate data stream) from being downloaded via a browser on
        # Server A, Windows can silently block/warn on running it
        # non-interactively (no console session to click "Run anyway" on) -
        # a very plausible cause of the generic RemoteException seen below.
        # Unblock-File is a harmless no-op if the file is already clean.
        try { Unblock-File -Path $lgpoExe -ErrorAction SilentlyContinue } catch {}

        $lgpoBackupDir = Join-Path $gpoBackupDir "LGPO"
        New-Item -ItemType Directory -Path $lgpoBackupDir -Force | Out-Null
        try {
            $lgpoLog = Join-Path $lgpoBackupDir "lgpo_backup.log"
            & $lgpoExe /b $lgpoBackupDir *> $lgpoLog
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Local GPO backed up via LGPO.exe -> $lgpoBackupDir (restorable with 'LGPO.exe /g <folder>')."
            } else {
                Write-Log "LGPO.exe /b returned exit code $LASTEXITCODE (non-blocking) - see $lgpoLog." "WARN"
            }
        } catch {
            # PowerShell's remoting layer wraps errors from native commands
            # invoked inside an Invoke-Command session as a generic
            # System.Management.Automation.RemoteException that typically
            # loses the ACTUAL error text ($_ alone is unhelpful here, as
            # observed in practice). The real diagnostic detail (whatever
            # LGPO.exe itself managed to write before failing) is already
            # captured in $lgpoLog via the *> redirection - surface its tail
            # instead of the useless generic wrapper message.
            $lgpoLogTail = if (Test-Path $lgpoLog) { ((Get-Content -Path $lgpoLog -Tail 5 -ErrorAction SilentlyContinue) -join ' | ') } else { "(no log output captured)" }
            Write-Log "LGPO.exe backup failed (non-blocking): $($_.Exception.GetType().FullName) - $lgpoLogTail" "WARN"
        }
        foreach ($polSpec in @(
                @{ Path = "C:\Windows\System32\GroupPolicy\Machine\Registry.pol"; Name = "Machine" },
                @{ Path = "C:\Windows\System32\GroupPolicy\User\Registry.pol";    Name = "User" })) {
            if (Test-Path $polSpec.Path) {
                $parsedTxt = Join-Path $lgpoBackupDir "$($polSpec.Name)_Registry.pol.txt"
                try {
                    & $lgpoExe /parse /m $polSpec.Path *> $parsedTxt
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log "Parsed $($polSpec.Name) Registry.pol to readable text -> $parsedTxt"
                    } else {
                        Write-Log "LGPO.exe /parse for $($polSpec.Name) Registry.pol returned exit code $LASTEXITCODE (non-blocking) - see $parsedTxt." "WARN"
                    }
                } catch {
                    $parsedTail = if (Test-Path $parsedTxt) { ((Get-Content -Path $parsedTxt -Tail 5 -ErrorAction SilentlyContinue) -join ' | ') } else { "(no log output captured)" }
                    Write-Log "LGPO.exe /parse failed for $($polSpec.Name) Registry.pol (non-blocking): $($_.Exception.GetType().FullName) - $parsedTail" "WARN"
                }
            }
        }
    } else {
        Write-Log "LGPO.exe not found alongside this script - skipping LGPO-based GPO export (non-blocking). Place LGPO.exe next to Start-TargetUpgrade.ps1 on Server A to enable a portable, restorable Local GPO backup in addition to the raw folder copy above." "WARN"
    }
    Update-BackupProgress -TaskName "LGPO.exe-based GPO backup"
    try {
        $secpolCfg = Join-Path $gpoBackupDir "SecurityPolicy.cfg"
        $secpolLog = Join-Path $gpoBackupDir "secedit_export.log"
        & secedit.exe /export /cfg $secpolCfg /log $secpolLog | Out-Null
        Write-Log "Local security/password policy exported via secedit.exe -> $secpolCfg"
    } catch {
        Write-Log "secedit.exe security policy export failed (non-blocking): $_" "WARN"
    }
    Update-BackupProgress -TaskName "secedit security policy export"
    try {
        & gpresult.exe /H (Join-Path $gpoBackupDir "GPResult.html") /F 2>&1 | Out-Null
        Write-Log "gpresult.exe HTML report captured for reference."
    } catch {
        Write-Log "gpresult.exe report failed (non-blocking): $_" "WARN"
    }
    Update-BackupProgress -TaskName "gpresult report"

    # --- 3.3 RDS CAL license database (only if this IS the license server) -
    try {
        $rdsLicFeature = $null
        try { $rdsLicFeature = Get-WindowsFeature -Name RDS-Licensing -ErrorAction SilentlyContinue } catch {}
        if ($rdsLicFeature -and $rdsLicFeature.Installed) {
            $lserverPath = Join-Path $env:SystemRoot "System32\LServer"
            if (Test-Path $lserverPath) {
                $rdsBackupDir = Join-Path $backupFolder "RDSLicensing"
                New-Item -ItemType Directory -Path $rdsBackupDir -Force | Out-Null
                # Best-effort hot copy - the CAL database may be open while the
                # licensing service runs; robocopy retries briefly and skips
                # locked files rather than failing the whole backup.
                robocopy $lserverPath $rdsBackupDir /MIR /R:1 /W:1 /NFL /NDL /NJH | Out-Null
                Write-Log "RDS CAL licensing database (best-effort hot copy) backed up to $rdsBackupDir"
            } else {
                Write-Log "RDS-Licensing role installed but LServer folder not found at $lserverPath - skipping DB backup." "WARN"
            }
        } else {
            Write-Log "This server is not an RDS CAL license server - RDS CAL DB backup skipped."
        }
    } catch {
        Write-Log "RDS CAL license DB backup check failed (non-blocking): $_" "WARN"
    }
    Update-BackupProgress -TaskName "RDS CAL license DB backup"

    # --- 3.4 System State backup (wbadmin) ---------------------------------
    # Confirmed via Microsoft Learn ("wbadmin start systemstatebackup"):
    # -backupTarget only accepts a drive letter/GUID-based volume or a UNC
    # network share - never an arbitrary LOCAL subfolder - so this cannot be
    # written directly inside $backupFolder like the other artifacts above.
    # Targeted at $driveRoot instead (the SAME drive that hosts every other
    # backup this run) as the closest possible match to "alongside the other
    # backups"; wbadmin auto-creates "<drive>:\WindowsImageBackup\<computer>\"
    # there. A pointer file is left inside $backupFolder so anyone browsing
    # the per-run folder can still find where the real data landed.
    try {
        if ($SkipSystemStateBackup) {
            # Recorded in the registry/JSON so the change record shows this run
            # deliberately has no system state backup, rather than implying one
            # exists. Still counted as a completed backup step (same convention
            # as the RDS CAL task when the role isn't installed) so the 8-task
            # percentage still reaches 100%.
            Set-UpgradeRegistryValue -Name "SystemStateBackupPath" -Value "SKIPPED (-SkipSystemStateBackup)"
            "System state backup was SKIPPED for this run because -SkipSystemStateBackup was specified. No wbadmin system state backup exists for $($script:RunStamp)." |
                Out-File -FilePath (Join-Path $backupFolder "SystemStateBackup_Location.txt") -Encoding UTF8 -Force
            Write-Log "System state backup SKIPPED (-SkipSystemStateBackup specified). All other backup artifacts were still created under $backupFolder." "WARN"
        } else {
            $wsbFeature = Get-WindowsFeature -Name Windows-Server-Backup -ErrorAction SilentlyContinue
            if (-not $wsbFeature) { throw "Could not query the Windows-Server-Backup feature state." }
            if (-not $wsbFeature.Installed) {
                Write-Log "Windows Server Backup feature not installed - installing it now for system state backup."
                $installResult = Install-WindowsFeature -Name Windows-Server-Backup -ErrorAction Stop
                if (-not $installResult.Success) { throw "Install-WindowsFeature reported Success=`$false for Windows-Server-Backup." }
                if ($installResult.RestartNeeded -eq "Yes") {
                    Write-Log "Windows Server Backup feature installed but reports a pending restart - proceeding anyway (non-blocking)." "WARN"
                } else {
                    Write-Log "Windows Server Backup feature installed successfully."
                }
            }

            $wsbLog = Join-Path $backupFolder "SystemStateBackup_$($script:RunStamp).log"
            & wbadmin.exe start systemstatebackup "-backupTarget:$driveRoot" -quiet *> $wsbLog
            if ($LASTEXITCODE -eq 0) {
                $wsbActualPath = Join-Path $driveRoot "WindowsImageBackup\$env:COMPUTERNAME"
                Set-UpgradeRegistryValue -Name "SystemStateBackupPath" -Value $wsbActualPath
                "System state backup completed: $wsbActualPath (full wbadmin output: $wsbLog)" |
                    Out-File -FilePath (Join-Path $backupFolder "SystemStateBackup_Location.txt") -Encoding UTF8 -Force
                Write-Log "System state backup completed via wbadmin -> $wsbActualPath (log: $wsbLog)"
            } else {
                Write-Log "wbadmin start systemstatebackup returned exit code $LASTEXITCODE (non-blocking) - see $wsbLog." "WARN"
            }
        }
    } catch {
        Write-Log "System state backup step failed (non-blocking): $_" "WARN"
    }
    Update-BackupProgress -TaskName $(if ($SkipSystemStateBackup) { "System state backup (SKIPPED)" } else { "System state backup (wbadmin)" })

    Set-Phase -Phase 2 -PhaseName "State & Policy Backup" -Status "InProgress" -Notes "Backup completed at $backupFolder"
} catch {
    # Aligned to 0 (was an inconsistent leftover "5") - a failed backup
    # genuinely completed 0% of anything meaningful, matching Phase 1's own
    # Failed-path convention above.
    Set-Phase -Phase 2 -PhaseName "State & Policy Backup" -Status "Failed" -PercentComplete 0 `
        -ProgressSource "BackupFailure" -ProgressFreshness "Terminal" -Notes "$_"
    Write-Log "Backup phase failed critically - terminating: $_" "ERROR"
    throw
}

# =============================================================================
# SECTION 4 - RECORD BASELINE + STAGE COMPANION SCRIPTS + SCHEDULED TASKS
# =============================================================================
$osInfo      = Get-CimInstance Win32_OperatingSystem
$sourceBuild = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
$sourceEditionId = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name EditionID -ErrorAction SilentlyContinue).EditionID
Set-UpgradeRegistryValue -Name "SourceBuild"  -Value $sourceBuild
Set-UpgradeRegistryValue -Name "SourceOSCaption" -Value $osInfo.Caption
Set-UpgradeRegistryValue -Name "SourceEditionId" -Value $sourceEditionId
Set-UpgradeRegistryValue -Name "IsoPath"      -Value $isoInfo.IsoPath
Set-UpgradeRegistryValue -Name "StatusJsonPath" -Value $script:StatusJson
# Safety net: if the edition-match check above could not derive TargetBuild
# (e.g. it only produced a WARN because install.wim/.esd couldn't be read),
# fall back to inspecting the media directly here so phase detection
# (First Boot / OOBE) still has a usable target build number to compare against.
if (-not (Get-ItemProperty $script:RegRoot -Name "TargetBuild" -ErrorAction SilentlyContinue).TargetBuild) {
    try {
        $wimFallback = Join-Path (Split-Path $isoInfo.SetupPath -Parent) "sources\install.wim"
        if (-not (Test-Path $wimFallback)) { $wimFallback = Join-Path (Split-Path $isoInfo.SetupPath -Parent) "sources\install.esd" }
        $img = Get-WindowsImage -ImagePath $wimFallback -Index 1 -ErrorAction Stop
        $verParts = $img.Version -split '\.'
        if ($verParts.Count -ge 3) {
            Set-UpgradeRegistryValue -Name "TargetBuild" -Value $verParts[2]
            Write-Log "Target build number derived from media (fallback): $($verParts[2])"
        }
    } catch {
        Write-Log "Could not derive TargetBuild from media (non-blocking) - First Boot/OOBE phase detection may be less precise: $_" "WARN"
    }
}
Write-Log "Current OS: $($osInfo.Caption) build $sourceBuild. Upgrade media: $($isoInfo.IsoPath) ($($isoInfo.DriveLetter):)"

# Copy this script's companions (status tracker, cleanup, hooks) to the
# ProgramData location that survives the whole upgrade so scheduled tasks /
# setup.exe hooks always reference a stable, persistent path.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($f in @("OSUpgradeStatus.ps1","Update-UpgradeStatus.ps1","Remove-UpgradeArtifacts.ps1","setupcomplete.cmd","setuprollback.cmd","LGPO.exe")) {
    $src = Join-Path $here $f
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $script:ScriptsDir -Force
    } elseif ($f -eq "LGPO.exe") {
        Write-Log "Optional companion 'LGPO.exe' not found next to this script - LGPO-based Local GPO backup was skipped earlier (non-blocking)." "WARN"
    } else {
        Write-Log "Companion file '$f' not found next to this script - copy it manually into $script:ScriptsDir before relying on phase tracking / hooks." "WARN"
    }
}

# --- Register recurring and boot-driven phase/progress monitoring ------------
$monitorScript = Join-Path $script:ScriptsDir "Update-UpgradeStatus.ps1"
$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$monitorScript`""
$periodicTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3)
$startupTrigger  = New-ScheduledTaskTrigger -AtStartup
$eventTriggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace "Root/Microsoft/Windows/TaskScheduler"
$bootEventTrigger = New-CimInstance -CimClass $eventTriggerClass -ClientOnly
$bootEventTrigger.Subscription = @'
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[(EventID=12 and Provider[@Name='Microsoft-Windows-Kernel-General']) or (EventID=6005 and Provider[@Name='EventLog'])]]</Select></Query></QueryList>
'@
$bootEventTrigger.Enabled = $true
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

Unregister-ScheduledTask -TaskName $script:TaskMonitor -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $script:TaskMonitor -Action $action `
    -Trigger @($periodicTrigger, $startupTrigger, $bootEventTrigger) -Principal $principal -Settings $settings | Out-Null
Write-Log "Registered scheduled task '$script:TaskMonitor' (every 1 min, at startup, and on System events 12/6005). LastBootUpTime is the unique reboot signal; events 12/6005 are corroboration."

# --- Register the event-triggered Safe OS watcher (Event ID 1074) -----------
try {
    Unregister-ScheduledTask -TaskName $script:TaskReboot -Confirm:$false -ErrorAction SilentlyContinue
    $regCmds = @(
        "reg.exe add `"HKLM\SOFTWARE\OSUpgradeAutomation`" /v Phase /t REG_DWORD /d 4 /f"
        "reg.exe add `"HKLM\SOFTWARE\OSUpgradeAutomation`" /v PhaseName /t REG_SZ /d `"Safe OS Phase`" /f"
        "reg.exe add `"HKLM\SOFTWARE\OSUpgradeAutomation`" /v Status /t REG_SZ /d `"InProgress`" /f"
        "reg.exe add `"HKLM\SOFTWARE\OSUpgradeAutomation`" /v Notes /t REG_SZ /d `"Reboot into Safe OS/WinPE detected via Event ID 1074 - unreachable until First Boot.`" /f"
        "reg.exe add `"HKLM\SOFTWARE\OSUpgradeAutomation`" /v ExpectedDisconnect /t REG_DWORD /d 1 /f"
        "reg.exe add `"HKLM\SOFTWARE\OSUpgradeAutomation`" /v ProgressFreshness /t REG_SZ /d `"CarriedForward`" /f"
        "reg.exe add `"HKLM\SOFTWARE\OSUpgradeAutomation`" /v LastUpdated /t REG_SZ /d `"%date% %time%`" /f"
    )
    # The first action is intentionally cmd/reg.exe for the narrow shutdown
    # window. The second action publishes the same transition atomically to
    # JSON and the durable history through the shared PowerShell contract.
    $rebootAction = New-ScheduledTaskAction -Execute "cmd.exe" -Argument ("/c " + ($regCmds -join " && "))
    $rebootPublishAction = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$monitorScript`" -RebootInitiated"
    $eventTrigger = New-CimInstance -CimClass $eventTriggerClass -ClientOnly
    $eventTrigger.Subscription = @'
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name='User32'] and EventID=1074]]</Select></Query></QueryList>
'@
    $eventTrigger.Enabled = $true
    Register-ScheduledTask -TaskName $script:TaskReboot -Action @($rebootAction, $rebootPublishAction) -Trigger $eventTrigger -Principal $principal -Settings $settings | Out-Null
    Write-Log "Registered event-triggered task '$script:TaskReboot' (Event 1074) to mark Safe OS and publish JSON before shutdown."
} catch {
    Write-Log "Could not register Safe OS event watcher (non-blocking, best-effort): $_" "WARN"
}

# --- Register the retention-based auto-cleanup task --------------------------
if (-not $DisableAutoCleanup) {
    try {
        Unregister-ScheduledTask -TaskName $script:TaskCleanup -Confirm:$false -ErrorAction SilentlyContinue
        $cleanupScript  = Join-Path $script:ScriptsDir "Remove-UpgradeArtifacts.ps1"
        $cleanupAction  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$cleanupScript`""
        $cleanupTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddDays($RetentionDays))
        Register-ScheduledTask -TaskName $script:TaskCleanup -Action $cleanupAction -Trigger $cleanupTrigger -Principal $principal -Settings $settings | Out-Null
        Write-Log "Registered '$script:TaskCleanup' to auto-purge registry/JSON/artifacts after $RetentionDays day(s) (only if terminal state reached by then)."
    } catch {
        Write-Log "Could not register auto-cleanup task (non-blocking): $_" "WARN"
    }
} else {
    Write-Log "Auto-cleanup disabled (-DisableAutoCleanup) - run Remove-UpgradeArtifacts.ps1 manually when ready."
}

# =============================================================================
# SECTION 5 - LAUNCH WINDOWS SETUP
# =============================================================================
# Setup starts at 0% on its local scale, which maps to the stable 25% overall
# handoff boundary. The recurring monitor replaces that local value only with
# Microsoft's MoSetup SetupProgress counter; if the counter is unavailable,
# the last verified value is carried forward with explicit freshness metadata.
Set-Phase -Phase 3 -PhaseName "Downlevel Phase" -Status "InProgress" -PercentComplete 0 `
    -PercentSource "Measured" -ProgressSource "StageBoundary.SetupLaunch" -ProgressFreshness "Milestone" `
    -Notes "Launching setup.exe"

$postOobeCmd     = Join-Path $script:ScriptsDir "setupcomplete.cmd"
$postRollbackCmd = Join-Path $script:ScriptsDir "setuprollback.cmd"

# /Telemetry Disable stops Setup from trying to reach its OneSettings/
# telemetry endpoints online - on a network-isolated/no-internet lab or
# restricted-egress server, that call can time out (observed: setuperr.log
# "OneSettings initialization failed: [0x80072EE2]" = ERROR_INTERNET_TIMEOUT)
# and eventually leads Setup to self-cancel ~30+ minutes later
# ("OnCancel...Result = 0x800704C7" = ERROR_CANCELLED), aborting the whole
# upgrade before it ever reaches Safe OS/WinPE - misread by our own phase
# heuristic as "about to reboot" since $WINDOWS.~BT is left behind with no
# process running. Confirmed via SetupDiagResults.xml/setuperr.log on TestVM1.
$setupArgs = @(
    "/Auto", "Upgrade",
    "/Quiet",
    "/DynamicUpdate", "Disable",
    "/Telemetry", "Disable",
    "/Compat", "IgnoreWarning",
    "/PostOOBE", "`"$postOobeCmd`"",
    "/PostRollback", "`"$postRollbackCmd`"",
    "/PostRollbackContext", "System"
)
if ($script:MatchedImageIndex) {
    # Required whenever install.wim has more than one applicable image -
    # without it, Setup's own auto-detection can fail outright under /Quiet
    # with MOSETUP_E_NO_MATCHING_INSTALL_IMAGE (0xC1900215). See the
    # edition-match precheck above for how this index was determined.
    $setupArgs += @("/ImageIndex", $script:MatchedImageIndex)
} else {
    Write-Log "No pre-matched WIM image index available (edition-match precheck could not determine one) - launching setup.exe WITHOUT /ImageIndex. If install.wim has multiple applicable images, this can fail with MOSETUP_E_NO_MATCHING_INSTALL_IMAGE (0xC1900215)." "WARN"
}
if ($UseControlledReboot) { $setupArgs += "/NoReboot" }

$setupProcNames = @("setup","SetupHost","SetupPrep")

try {
    Write-Log "Launching: $($isoInfo.SetupPath) $($setupArgs -join ' ')"

    # Launch setup.exe via a locally-registered, immediately-triggered
    # Scheduled Task (SYSTEM/Highest) instead of Start-Process directly in
    # this script's own process tree. This script itself is running inside
    # an Invoke-Command -Session (WinRM) remote runspace, and a child process
    # started there inherits that session's restricted, non-interactive
    # window station/logon session - Windows Setup has well-documented cases
    # of silently failing or hanging (no fresh Panther logs, no visible
    # engine process, no error) when launched that way. A Scheduled Task runs
    # in its own proper session context, decoupled from the transient WinRM
    # connection - the same supported approach tools like SCCM/MDT use, and
    # already used elsewhere in this script for the monitor/watcher tasks.
    Unregister-ScheduledTask -TaskName $script:TaskSetupRun -Confirm:$false -ErrorAction SilentlyContinue
    $setupAction  = New-ScheduledTaskAction -Execute $isoInfo.SetupPath -Argument ($setupArgs -join ' ')
    $setupTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
    Register-ScheduledTask -TaskName $script:TaskSetupRun -Action $setupAction -Trigger $setupTrigger -Principal $principal -Settings $settings | Out-Null
    Set-UpgradeRegistryValue -Name "SetupLaunchTimeUtc" -Value ([DateTimeOffset]::UtcNow.ToString("o"))
    Start-ScheduledTask -TaskName $script:TaskSetupRun
    Start-ScheduledTask -TaskName $script:TaskMonitor -ErrorAction SilentlyContinue
    Write-Log "setup.exe launch handed off to Scheduled Task '$script:TaskSetupRun' (decoupled from this WinRM session)."

    # Confirm the engine actually started (poll up to ~60s) before moving on.
    $launched = $false
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Seconds 5
        if (Get-Process -Name $setupProcNames -ErrorAction SilentlyContinue) { $launched = $true; break }
    }
    if ($launched) {
        Write-Log "Confirmed setup.exe process is running. This script does NOT wait for the full upgrade - progress is tracked via the '$script:TaskMonitor' scheduled task and $script:StatusJson from here on."
    } else {
        Write-Log "setup.exe process was not observed running within 60s of the scheduled-task launch - it may still be starting slowly, or may have failed. Check Task Scheduler history for '$script:TaskSetupRun' and the Panther setupact.log/setuperr.log on $env:COMPUTERNAME." "WARN"
    }

    if ($UseControlledReboot) {
        Write-Log "UseControlledReboot specified: waiting for the setup.exe process to exit before triggering the first restart..."
        while (Get-Process -Name $setupProcNames -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 15 }
        Write-Log "setup.exe process(es) exited. Triggering controlled restart in 60 seconds."
        # No fabricated percentage here either (was a hardcoded 25%) - by
        # this point real Measured data from setupact.log/mosetup registry
        # has likely already progressed well past any such guess; simply
        # leave the last real value in place.
        Set-Phase -Phase 3 -PhaseName "Downlevel Phase" -Status "InProgress" -Notes "Staging complete; controlled reboot imminent."
        Start-Sleep -Seconds 60
        Restart-Computer -Force
    }
} catch {
    Set-Phase -Phase 3 -PhaseName "Downlevel Phase" -Status "Failed" -PercentComplete 0 `
        -ProgressSource "SetupLaunch" -ProgressFreshness "Terminal" -Notes "Failed to launch setup.exe via Scheduled Task: $_"
    Write-Log "Failed to launch setup.exe via Scheduled Task: $_" "ERROR"
    throw
}

Write-Log "Start-TargetUpgrade.ps1 completed its kickoff work and is exiting. Monitor $env:COMPUTERNAME from Server A using Start-RemoteUpgradeOrchestrator.ps1."
