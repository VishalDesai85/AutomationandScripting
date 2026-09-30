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

.PARAMETER SkipDismScanHealthLab
    LAB/TEST-ONLY PERFORMANCE OVERRIDE. Skip the read-only
    `Dism /Online /Cleanup-Image /ScanHealth` pre-check and record that check
    as WARN. This leaves component-store health unverified and must never be
    used for production acceptance or rollout.

.PARAMETER SkipSfcScanNowLab
    LAB/TEST-ONLY PERFORMANCE OVERRIDE. Skip `sfc /scannow` and its
    supplementary CBS.log analysis, recording that check as WARN. This leaves
    protected Windows system-file integrity unverified and must never be used
    for production acceptance or rollout.

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

.PARAMETER PrecheckOnly
    Run pre-checks only. Do not perform state backup, register scheduled
    tasks, or launch setup.exe. Useful for fast assessment verification.

.EXAMPLE
    Local/manual test run on Server B:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-TargetUpgrade.ps1" -IsoFolder "D:\ISO"

.EXAMPLE
    Lab run bypassing only the patch-currency hard stop:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-TargetUpgrade.ps1" -SkipPatchCheckLab

.EXAMPLE
    Faster disposable-lab run, skipping DISM, SFC, and system state backup:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-TargetUpgrade.ps1" -SkipDismScanHealthLab -SkipSfcScanNowLab -SkipSystemStateBackup
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
    [switch]$SkipDismScanHealthLab,
    [switch]$SkipSfcScanNowLab,
    [switch]$SkipSystemStateBackup,
    [string]$MinVMwareToolsVersion = "12.0.0",
    [switch]$UseControlledReboot,
    [int]   $MaxPatchAgeDays    = 60,
    [switch]$PrecheckOnly
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
    # PERF (2026-09-26): was Add-Content, which routes through PowerShell's
    # whole provider stack (path resolution, encoding negotiation, open,
    # write, close) on EVERY call - and this script calls Write-Log ~170
    # times per run, several of them inside tight pre-check/backup loops.
    # [System.IO.File]::AppendAllText does the same open-append-close in one
    # native call, roughly an order of magnitude cheaper, with the SAME
    # durability (flushed and closed before returning) and the SAME tiny lock
    # window - deliberately NOT a long-lived StreamWriter, which would hold
    # the log open for the entire run and block Remove-UpgradeArtifacts.ps1
    # from deleting the Logs folder.
    # Encoding::UTF8 matches Add-Content -Encoding UTF8 exactly: the BOM is
    # emitted only when the file is created, not on every append.
    # WRAPPED (2026-09-26): a transient log-write failure (AV scanner holding
    # the file, disk momentarily full) used to be a TERMINATING error under
    # $ErrorActionPreference='Stop' and could abort an in-flight OS upgrade.
    # Losing a log line is never worth that; the console output above still
    # reaches Server A's live stream either way.
    try {
        [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch {
        Write-Host "[LOGGING] Could not append to $script:LogFile (continuing): $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

# --- Shared status helpers ----------------------------------------------------
# Set-UpgradeRegistryValue / Get-UpgradeRegistryValue / Write-StatusJson /
# Set-Phase used to be copy-pasted into BOTH this script and
# Update-UpgradeStatus.ps1, which had already caused two real divergence bugs
# (the per-stage percent clamp landing in only one copy; the two Write-StatusJson
# field lists drifting apart). They now live in ONE file that both dot-source.
# MUST come after Write-Log above (Set-Phase calls it) and after the
# $script:RegRoot / $script:StatusJson assignments in Section 0 (the shared
# functions read both).
# Fail-fast by design: if the companion is missing we stop HERE, before a
# single change has been made to this server - never half-way through.
$script:SharedHelpers = Join-Path $PSScriptRoot "OSUpgradeShared.ps1"
if (-not (Test-Path $script:SharedHelpers)) {
    throw "Required companion 'OSUpgradeShared.ps1' was not found next to this script ($PSScriptRoot). It carries the shared status/phase tracking functions - staging is incomplete. Re-run the orchestrator (it stages this file automatically), or copy it manually, then retry. Nothing has been changed on this server."
}
. $script:SharedHelpers

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

# --- Mutex Protection ---------------------------------------------------------
# Multiple concurrent invocations on Server B (e.g. rapid orchestrator triggers
# or overlapping automated runs) must not stomp over staging, registry state,
# or setup.exe execution.
$script:StarterMutex = [System.Threading.Mutex]::new($false, "Global\OSUpgradeAutomation.StartTargetUpgrade")
$script:OwnsStarterMutex = $false
try {
    try {
        $script:OwnsStarterMutex = $script:StarterMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $script:OwnsStarterMutex = $true
    }
    if (-not $script:OwnsStarterMutex) {
        Write-Log "Another instance of Start-TargetUpgrade.ps1 is already running on $env:COMPUTERNAME. Terminating this execution." "ERROR"
        throw "Another instance of Start-TargetUpgrade.ps1 is already active on this host."
    }

    try {
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

# No -PercentComplete here (2026-07-20, per feedback: an arbitrary "0%"/
# "5%"/"15%" milestone for prechecks/backup doesn't represent anything
# measurable the way Stage 3's real setup.exe telemetry does, and risks
# looking like meaningful progress data when it's really just a guess).
# Stage 1/2 now show Stage+Phase+Status with no percent number at all; a
# fresh run's registry has no prior PercentComplete yet, so Set-Phase's own
# display-fallback resolves this to a plain 0 anyway.
Set-Phase -Phase 1 -PhaseName "Pre-Upgrade Assessment" -Status "InProgress"

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
# check", "VMware Tools up-to-date (VMware VM detected)") and the ISO edition
# check interpolates the detected edition into its name - so counting DISTINCT
# NAME STRINGS gives 16 and is the wrong way to verify this number. What
# matters is that each of the 14 checks reports exactly ONCE per run: every
# check has mutually exclusive PASS/WARN/FAIL branches, each ending in a
# single Add-PreCheckResult call, so a plain running counter is accurate.
# Section 2c asserts the final count against this constant at runtime rather
# than relying on this comment staying true.
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
    Set-Phase -Phase 1 -PhaseName "Pre-Upgrade Assessment" -Status "InProgress" -PercentComplete $pct -PercentSource "Measured" -ProgressFreshness "Milestone" -Notes "Check $script:precheckStepsDone/$totalPrecheckSteps complete: $Name ($Result)"
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
    $pendingReasons = @()
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
        $pendingReasons += "CBS RebootPending key present"
    }
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
        $pendingReasons += "Windows Update RebootRequired key present"
    }
    $pfro = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
    if ($pfro -and $pfro.PendingFileRenameOperations) {
        $pendingReasons += "PendingFileRenameOperations present (rename operation pending)"
    }
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
# does). Every pre-check still runs to completion regardless (this check
# does NOT `throw` here - it only appends to $hardFailures, same as every
# other check - see Section 2c's single aggregated throw at the very end),
# so the admin sees every failing item in one shot and can resolve them all
# before re-initiating the upgrade. Only genuinely INCONCLUSIVE outcomes
# (DISM couldn't even run, or its output couldn't be parsed) stay WARN -
# uncertainty about whether a problem exists is not the same as a confirmed
# finding.
if ($SkipDismScanHealthLab) {
    Add-PreCheckResult -Name "Component store health (DISM ScanHealth)" -Result "WARN" -Detail "SKIPPED by explicit LAB/TEST override -SkipDismScanHealthLab. Component-store health was NOT validated. This override applies only to DISM; see the separate SFC check result. Do not use this result for production acceptance."
} else {
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
if ($SkipSfcScanNowLab) {
    Add-PreCheckResult -Name "System file integrity (SFC /scannow)" -Result "WARN" -Detail "SKIPPED by explicit LAB/TEST override -SkipSfcScanNowLab. Protected Windows system-file integrity was NOT validated and CBS.log was not analyzed. Do not use this result for production acceptance."
} else {
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
        # Must still REPORT (not merely log) that this check ran, exactly like
        # the VMware Tools check does on a non-VMware host above. Reporting is
        # what increments $script:precheckStepsDone - so the previous
        # log-and-move-on left every non-RDS server counting 13 of 14 checks,
        # and Stage 1 visibly ended at 92% instead of 100% before handing over
        # to Stage 2. (Caught 2026-09-26 by the step-count self-check added at
        # the end of Section 2c.)
        Add-PreCheckResult -Name "RDS Session Host CAL license server check" -Result "PASS" -Detail "RD Session Host role not installed - RDS CAL licensing check not applicable."
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

        # A ready-to-run cleanup script is made available (never auto-executed)
        # next to this script in the staging folder, so the admin has a third,
        # zero-copy-paste option alongside the printed per-SID commands and the
        # printed bulk script.
        # CHANGED 2026-09-26: that script used to be GENERATED right here from
        # a 341-line here-string embedded in this file. It now SHIPS as a real
        # file (ServerB-Target\Remove-OrphanedProfiles.ps1, staged next to this
        # one by the orchestrator, exactly like Update-UpgradeStatus.ps1 and
        # the two .cmd hooks) so it gets syntax highlighting, linting and
        # PSScriptAnalyzer coverage instead of being opaque text inside a
        # string. What the admin sees and runs is byte-for-byte the same
        # script; only where it comes from changed. If the file is missing
        # (e.g. hand-copied staging that omitted it), Options 1 and 2 below
        # are unaffected - only this convenience option is skipped, exactly
        # as it already was whenever the old generation step failed.
        $orphanScriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { "C:\Temp\OSUpgradeStaging" }
        $orphanScriptPath = Join-Path $orphanScriptDir "Remove-OrphanedProfiles.ps1"
        $orphanScriptWritten = Test-Path $orphanScriptPath
        if ($orphanScriptWritten) {
            Set-UpgradeRegistryValue -Name "OrphanCleanupScriptPath" -Value $orphanScriptPath
        } else {
            Write-Log "Companion 'Remove-OrphanedProfiles.ps1' is not present at $orphanScriptPath - the ready-to-run cleanup option is unavailable this run; the copy/paste options printed below are unaffected." "WARN"
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
        Write-Log " OPTION 3 - RUN THE READY-MADE SCRIPT ALREADY STAGED ON THIS SERVER"
        Write-Log "--------------------------------------------------------------------"
        if ($orphanScriptWritten) {
            Write-Log " A ready-to-run cleanup script is already staged on $env:COMPUTERNAME at:"
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
            Write-Log " (Unavailable this run - Remove-OrphanedProfiles.ps1 was not staged to"
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

# DRIFT SELF-CHECK (2026-09-26). $totalPrecheckSteps is a hand-maintained
# constant feeding a customer-visible percentage, and getting it wrong breaks
# nothing - which is exactly why it drifts unnoticed. A check ADDED without
# bumping it makes Stage 1 hit 100% early and sit there; a check REMOVED, or
# one that returns without reporting (how the RDS CAL check behaved on every
# non-RDS server until today), makes Stage 1 end BELOW 100%. Assert the real
# number here instead of trusting the inventory comment in Section 2 to stay
# accurate. Deliberately a WARN, never a throw: a miscounted progress bar is
# not a reason to abort an otherwise healthy upgrade.
if ($script:precheckStepsDone -ne $totalPrecheckSteps) {
    $actualEndPct = [math]::Min(100, [int](100.0 * $script:precheckStepsDone / $totalPrecheckSteps))
    Write-Log ("Pre-check step-count drift: $script:precheckStepsDone checks actually reported, but `$totalPrecheckSteps says $totalPrecheckSteps. Stage 1's percentage was wrong this run (ended at $actualEndPct%, not 100%); the upgrade itself is unaffected. Update the constant - and the check inventory comment beside it - to match the real number of checks that call Add-PreCheckResult.") "WARN"
}

if ($hardFailures.Count -gt 0) {
    $msg = ($hardFailures -join " | ")
    Set-Phase -Phase 1 -PhaseName "Pre-Upgrade Assessment" -Status "Failed" -PercentComplete 0 -Notes $msg
    Write-Log "PRE-CHECK GATE FAILED - terminating immediately. Details: $msg" "ERROR"
    throw "Pre-upgrade assessment failed: $msg"
}
Write-Log "All hard-fail pre-checks PASSED. Warnings (non-blocking): $($warnings.Count)"
foreach ($w in $warnings) { Write-Log "  - $w" "WARN" }

if ($PrecheckOnly) {
    Set-Phase -Phase 1 -PhaseName "Pre-Upgrade Assessment" -Status "AssessmentPassed" -PercentComplete 100 -PercentSource "Measured" -ProgressFreshness "Milestone" -Notes "PrecheckOnly completed successfully. Backup and setup were skipped by request."
    Write-Log "PrecheckOnly switch is set: all pre-checks passed. Exiting cleanly without proceeding to backup or setup.exe launch." "PASS"
    return
}

# =============================================================================
# SECTION 3 - STATE & POLICY BACKUP  (D:\UpgradeBackup by default)
# =============================================================================
# Same reasoning as Phase 1 above - no fabricated milestone percent at
# kickoff (0/M tasks done yet - Update-BackupProgress below reports real
# progress as each task actually finishes).
Set-Phase -Phase 2 -PhaseName "State & Policy Backup" -Status "InProgress"

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
    Set-Phase -Phase 2 -PhaseName "State & Policy Backup" -Status "InProgress" -PercentComplete $pct -PercentSource "Measured" -ProgressFreshness "Milestone" -Notes "Task $script:backupStepsDone/$totalBackupSteps complete: $TaskName"
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

    # --- 3.0b Host environment & configuration diagnostics -----------------
    try {
        Write-Log "Capturing host configuration diagnostics (computerinfo, systeminfo, ipconfig)..."
        $compInfoPath = Join-Path $backupFolder "computerinfo.txt"
        Get-ComputerInfo -Property WindowsBuildLabEx,WindowsEditionID -ErrorAction SilentlyContinue |
            Out-File -FilePath $compInfoPath -Encoding UTF8
        # Also copy to root BackupRoot for immediate accessibility
        Copy-Item -Path $compInfoPath -Destination (Join-Path $BackupRoot "computerinfo.txt") -Force -ErrorAction SilentlyContinue

        $sysInfoPath = Join-Path $backupFolder "systeminfo.txt"
        & systeminfo.exe | Out-File -FilePath $sysInfoPath -Encoding UTF8
        Copy-Item -Path $sysInfoPath -Destination (Join-Path $BackupRoot "systeminfo.txt") -Force -ErrorAction SilentlyContinue

        $ipConfigPath = Join-Path $backupFolder "ipconfig.txt"
        & ipconfig.exe /all | Out-File -FilePath $ipConfigPath -Encoding UTF8
        Copy-Item -Path $ipConfigPath -Destination (Join-Path $BackupRoot "ipconfig.txt") -Force -ErrorAction SilentlyContinue

        Write-Log "Host configuration diagnostics saved to $backupFolder and copied to $BackupRoot."
    } catch {
        Write-Log "Failed to collect one or more host configuration diagnostics (non-blocking): $_" "WARN"
    }

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
                    throw "Windows Server Backup was installed but requires a restart. Reboot the target, rerun -PrecheckOnly, then restart the full upgrade so wbadmin runs from a settled servicing state."
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
                throw "wbadmin start systemstatebackup returned exit code $LASTEXITCODE. Required recovery evidence was not created; see $wsbLog."
            }
        }
    } catch {
        Write-Log "Required system state backup failed - refusing to launch Windows Setup: $_" "ERROR"
        throw
    }
    Update-BackupProgress -TaskName $(if ($SkipSystemStateBackup) { "System state backup (SKIPPED)" } else { "System state backup (wbadmin)" })

    # Same drift self-check as Section 2c, for the same reason - $totalBackupSteps
    # is hand-maintained. Structurally this one is harder to get wrong (all 8
    # Update-BackupProgress calls sit unconditionally at the top level of this
    # try block, deliberately OUTSIDE each task's own try/catch and if/else, so
    # a skipped or failed task still counts as worked through), but the check
    # costs nothing and would catch a task added without bumping the constant.
    if ($script:backupStepsDone -ne $totalBackupSteps) {
        Write-Log ("Backup step-count drift: $script:backupStepsDone tasks actually reported, but `$totalBackupSteps says $totalBackupSteps. Stage 2's percentage was wrong this run; the backup itself is unaffected. Update the constant to match the real number of Update-BackupProgress calls.") "WARN"
    }

    Set-Phase -Phase 2 -PhaseName "State & Policy Backup" -Status "InProgress" -Notes "Backup completed at $backupFolder"
} catch {
    # Aligned to 0 (was an inconsistent leftover "5") - a failed backup
    # genuinely completed 0% of anything meaningful, matching Phase 1's own
    # Failed-path convention above.
    Set-Phase -Phase 2 -PhaseName "State & Policy Backup" -Status "Failed" -PercentComplete 0 -Notes "$_"
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
Set-UpgradeRegistryValue -Name "StartTime"    -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
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

# Copy this script's companions (status tracker, shared status plumbing,
# cleanup, hooks) to the ProgramData location that survives the whole upgrade
# so scheduled tasks / setup.exe hooks always reference a stable, persistent
# path.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($f in @("Update-UpgradeStatus.ps1","OSUpgradeShared.ps1","Remove-UpgradeArtifacts.ps1","setupcomplete.cmd","setuprollback.cmd","LGPO.exe")) {
    $src = Join-Path $here $f
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $script:ScriptsDir -Force
    } elseif ($f -eq "LGPO.exe") {
        Write-Log "Optional companion 'LGPO.exe' not found next to this script - LGPO-based Local GPO backup was skipped earlier (non-blocking)." "WARN"
    } elseif ($f -eq "OSUpgradeShared.ps1") {
        # Reaching this is close to impossible - this very script dot-sourced
        # that file at startup, so it existed minutes ago - but it is worth an
        # explicit hard stop rather than a warning. Update-UpgradeStatus.ps1
        # dot-sources it too and throws without it, so carrying on would hand
        # off to setup.exe with EVERY status channel permanently dead: the
        # 2-minute monitor, the reboot watcher and both setup.exe hooks would
        # each throw on entry, and Server A would watch a server reboot into
        # an upgrade it can never again get a phase, a percentage or a
        # completion signal out of. Stopping here still leaves the machine
        # fully intact (backup taken, nothing upgraded).
        throw "Companion 'OSUpgradeShared.ps1' has disappeared from $here since this script started. It carries the status-tracking functions that Update-UpgradeStatus.ps1 needs to report progress after reboot - refusing to launch setup.exe without it. Nothing has been upgraded; restore the file and re-run."
    } else {
        Write-Log "Companion file '$f' not found next to this script - copy it manually into $script:ScriptsDir before relying on phase tracking / hooks." "WARN"
    }
}

# --- Register the 5-minute phase/progress monitor ----------------------------
$monitorScript = Join-Path $script:ScriptsDir "Update-UpgradeStatus.ps1"
$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$monitorScript`""
# Interval shortened from 5 to 2 minutes (2026-07-20): on a fast upgrade, Safe
# OS + First Boot + OOBE can complete in well under 5 minutes combined - a
# 5-min cadence can miss First Boot's window entirely (no poll ever lands
# while the machine is specifically in that phase before the OOBE hook fires
# and jumps straight to Phase 6). 2 minutes meaningfully narrows that blind
# spot without materially increasing overhead (still a lightweight registry/
# log-tail read).
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

Unregister-ScheduledTask -TaskName $script:TaskMonitor -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $script:TaskMonitor -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
Write-Log "Registered scheduled task '$script:TaskMonitor' (every 2 min, persists across reboots)."

# --- Register the event-triggered Safe OS watcher (Event ID 1074) -----------
try {
    Unregister-ScheduledTask -TaskName $script:TaskReboot -Confirm:$false -ErrorAction SilentlyContinue
    $regCmds = @(
        "reg.exe add `"HKLM\SOFTWARE\OSUpgradeAutomation`" /v Phase /t REG_DWORD /d 4 /f"
        "reg.exe add `"HKLM\SOFTWARE\OSUpgradeAutomation`" /v PhaseName /t REG_SZ /d `"Safe OS Phase`" /f"
        "reg.exe add `"HKLM\SOFTWARE\OSUpgradeAutomation`" /v Status /t REG_SZ /d `"InProgress`" /f"
        "reg.exe add `"HKLM\SOFTWARE\OSUpgradeAutomation`" /v ExpectedDisconnect /t REG_DWORD /d 1 /f"
        "reg.exe add `"HKLM\SOFTWARE\OSUpgradeAutomation`" /v Notes /t REG_SZ /d `"Reboot into Safe OS/WinPE detected via Event ID 1074 - unreachable until First Boot.`" /f"
        "reg.exe add `"HKLM\SOFTWARE\OSUpgradeAutomation`" /v LastUpdated /t REG_SZ /d `"%date% %time%`" /f"
    )
    # This task deliberately runs via cmd.exe/reg.exe (not PowerShell) so it
    # fires instantly/reliably in the narrow pre-shutdown window right
    # before the real reboot - which means it can never call the Set-Phase
    # PowerShell function, and so never mirrors into OSUpgradeProgress.log
    # the way every other phase transition does. That left Phase 4 (Safe OS)
    # completely invisible in that durable log, even though the live
    # registry WAS updated correctly. Fix (2026-07-20): append one more
    # command to the SAME cmd.exe chain that echoes a matching line straight
    # into OSUpgradeProgress.log - no PowerShell dependency added, just a
    # plain redirected echo, using the already-known $backupFolder path
    # baked in at task-REGISTRATION time (this task itself only ever runs
    # once, later, when Event ID 1074 fires).
    #
    # Deliberately does NOT touch PercentComplete/PercentSource at all
    # anymore (2026-07-20 follow-up): this reg.exe chain used to hardcode a
    # fake "40% (Estimated)" Safe OS milestone, which could visibly LOWER
    # the displayed percentage below whatever real Downlevel reading (via
    # the MoSetup registry, sometimes already in the 90s%) had just been
    # measured moments before reboot - looking like a regression for no
    # reason. Simply not writing those two values here leaves the registry's
    # last real Measured percent untouched/still showing through Safe OS.
    if ($backupFolder -and (Test-Path $backupFolder)) {
        $progressLogPath = Join-Path $backupFolder "OSUpgradeProgress.log"
        $regCmds += "echo [%date% %time%] [Stage 3/3: Windows Setup Execution] Phase=4 (Safe OS Phase) Status=InProgress Reboot into Safe OS/WinPE detected via Event ID 1074 - unreachable until First Boot. Percent unchanged from last real Downlevel reading (no telemetry possible in WinPE). >> `"$progressLogPath`""
    }
    # Keep the direct registry writes first because they are the quickest path
    # in the narrow pre-shutdown window. Then let the mutex-protected shared
    # writer mirror ExpectedDisconnect and the carried progress into JSON.
    $regCmds += "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$monitorScript`" -RebootEvent"
    $rebootAction = New-ScheduledTaskAction -Execute "cmd.exe" -Argument ("/c " + ($regCmds -join " && "))
    $eventTriggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace "Root/Microsoft/Windows/TaskScheduler"
    $eventTrigger = New-CimInstance -CimClass $eventTriggerClass -ClientOnly
    $eventTrigger.Subscription = @'
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name='User32'] and EventID=1074]]</Select></Query></QueryList>
'@
    $eventTrigger.Enabled = $true
    Register-ScheduledTask -TaskName $script:TaskReboot -Action $rebootAction -Trigger $eventTrigger -Principal $principal -Settings $settings | Out-Null
    Write-Log "Registered event-triggered task '$script:TaskReboot' (fires on Event ID 1074) to mark Safe OS phase immediately."
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
# 0% (not an invented mid-range number) - this is the honest state the
# instant the Scheduled Task is about to fire: nothing measurable has
# happened yet. Update-UpgradeStatus.ps1 takes over within seconds and
# starts reporting Setup's OWN live "Overall progress" counter parsed from
# setupact.log, which is real, monitored data - showing an arbitrary
# placeholder here only to have it get overwritten moments later by a
# genuinely lower real number is the exact ambiguity this avoids at the
# source (rather than only patching around it via Set-Phase's monotonic
# clamp). Fix applied 2026-07-20: -PercentComplete is now genuinely omitted
# here (previously the comment above described this intent but the code
# still passed 0) - the registry simply keeps Phase 2's last real percent
# until Update-UpgradeStatus.ps1's own poll finds a real Measured value.
Set-Phase -Phase 3 -PhaseName "Downlevel Phase" -Status "InProgress" -Notes "Launching setup.exe"

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
    "/Eula", "Accept",
    "/DynamicUpdate", "Disable",
    "/Telemetry", "Disable",
    "/Compat", "IgnoreWarning",
    "/PostOOBE", "`"$postOobeCmd`"",
    "/PostRollback", "`"$postRollbackCmd`""
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
    Start-ScheduledTask -TaskName $script:TaskSetupRun
    Write-Log "setup.exe launch handed off to Scheduled Task '$script:TaskSetupRun' (decoupled from this WinRM session)."

    # Confirm the engine actually started (poll up to ~60s) before moving on.
    $launched = $false
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Seconds 5
        if (Get-Process -Name $setupProcNames -ErrorAction SilentlyContinue) { $launched = $true; break }
    }
    if ($launched) {
        Set-UpgradeRegistryValue -Name "SetupWasObserved" -Value 1 -Type DWord
        Set-UpgradeRegistryValue -Name "SetupLastObservedAtUtc" -Value ((Get-Date).ToUniversalTime().ToString("o"))
        Set-UpgradeRegistryValue -Name "ExpectedDisconnect" -Value 0 -Type DWord
        Remove-ItemProperty -Path $script:RegRoot -Name "SetupMissingSinceUtc" -ErrorAction SilentlyContinue
        Write-Log "Confirmed setup.exe process is running. This script does NOT wait for the full upgrade - progress is tracked via the '$script:TaskMonitor' scheduled task and $script:StatusJson from here on."
    } else {
        $setupTaskInfo = Get-ScheduledTaskInfo -TaskName $script:TaskSetupRun -ErrorAction SilentlyContinue
        $taskResult = if ($setupTaskInfo) { $setupTaskInfo.LastTaskResult } else { "unavailable" }
        throw "setup.exe was not observed within 60 seconds. Treating kickoff as failed rather than assuming a slow start. Scheduled-task LastTaskResult=$taskResult. Check '$script:TaskSetupRun' history and Panther setupact.log/setuperr.log."
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
    Set-Phase -Phase 3 -PhaseName "Downlevel Phase" -Status "Failed" -PercentComplete 0 -Notes "Failed to launch setup.exe via Scheduled Task: $_"
    Write-Log "Failed to launch setup.exe via Scheduled Task: $_" "ERROR"
    throw
}

Write-Log "Start-TargetUpgrade.ps1 completed its kickoff work and is exiting. Monitor $env:COMPUTERNAME from Server A using Start-RemoteUpgradeOrchestrator.ps1."

    } finally {
        # Outer execution body completes (or throws)
    }
} finally {
    if ($script:OwnsStarterMutex) {
        $script:StarterMutex.ReleaseMutex()
    }
    $script:StarterMutex.Dispose()
}
