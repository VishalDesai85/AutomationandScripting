<#
.SYNOPSIS
    Runs on a schedule (every 2 minutes, registered by Start-TargetUpgrade.ps1)
    on Server B. Detects which phase of the in-place upgrade is currently
    active, reads Windows Setup's Microsoft-documented MoSetup progress value,
    and writes the result to BOTH the registry
    (HKLM:\SOFTWARE\OSUpgradeAutomation) and the JSON status file
    (D:\upgrade_status.json) so Server A can read it either way.

.DESCRIPTION
    Phase model (kept identical to the numbers used by Start-TargetUpgrade.ps1
    and the setupcomplete.cmd / setuprollback.cmd hooks):
        1  Pre-Upgrade Assessment
        2  State & Policy Backup
        3  Downlevel Phase        (still on source build, setup.exe running)
        4  Safe OS Phase          (WinPE - blind window, no script can run)
        5  First Boot Phase       (new build booted, SystemSetupInProgress=1)
        6  Second Boot (OOBE) Phase (setupcomplete.cmd /PostOOBE fired)
        7  Post-Upgrade Validation / Completed
        99 Rolled Back / Failed   (setuprollback.cmd /PostRollback fired)

    HONEST LIMITATION (Safe OS / Phase 4): the machine boots into a temporary
    WinPE-like environment to apply the new image. No script or scheduled task
    can execute there. The event-triggered 'OSUpgradeRebootWatcher' task marks
    Phase 4 the instant a restart is initiated (Event ID 1074); after that,
    LastUpdated simply stops advancing until First Boot - this is the same
    heuristic SCCM/MDT-style dashboards use.

    Polls, hooks and -RebootEvent calls share mutexes with the starter and
    artifact cleanup (starter lock first, status lock second).
    Terminal registry state is retained if JSON publication fails, and the
    monitor retries publication before unregistering itself. A missing or
    mismatched target build fails validation; activation and service health
    findings on a verified target build produce CompletedWithWarnings.
    Successful transitions require PostUpgradeBuild, PostUpgradeValidationTime
    (UTC), and PostUpgradeValidationResult (Passed or PassedWithWarnings);
    these fields are written to both registry and JSON before completion.

.PARAMETER RebootEvent
    Called by the Event ID 1074 watcher. Marks an inferred Safe OS transition
    only while the run is InProgress in Downlevel/Safe OS, never after boot
    progression or terminal completion.
#>

[CmdletBinding()]
param(
    [switch]$RebootEvent
)

$ErrorActionPreference = "Stop"

# --- Shared constants (must match Start-TargetUpgrade.ps1) -------------------
$script:RegRoot     = "HKLM:\SOFTWARE\OSUpgradeAutomation"
$script:BaseDir     = "C:\ProgramData\OSUpgradeAutomation"
$script:ScriptsDir  = Join-Path $script:BaseDir "Scripts"
$script:LogDir      = Join-Path $script:BaseDir "Logs"
$script:MarkerOOBE  = Join-Path $script:BaseDir "postoobe.marker"
$script:MarkerRB    = Join-Path $script:BaseDir "rollback.marker"
$script:LogFile     = Join-Path $script:LogDir "Update-UpgradeStatus.log"

# Scheduled polls, reboot events and Setup hooks can overlap. Keep each
# read/transition/JSON publication together, including terminal validation.
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
    # Starter owns initial state/marker resets; never inspect a partial run.
    if (-not $ownsStarterMutex) { return }
    try {
        $ownsStatusMutex = $statusMutex.WaitOne(30000)
    } catch [System.Threading.AbandonedMutexException] {
        $ownsStatusMutex = $true
    }
    if (-not $ownsStatusMutex) { return }
    # An obsolete task/hook must not recreate a run after cleanup.
    if (-not (Test-Path $script:RegRoot)) { return }

# StatusJsonPath is read back from the registry (written by Start-TargetUpgrade.ps1)
# so this script does not need its own parameter to stay in sync.
$script:StatusJson = (Get-ItemProperty $script:RegRoot -Name "StatusJsonPath" -ErrorAction SilentlyContinue).StatusJsonPath
if (-not $script:StatusJson) { $script:StatusJson = "D:\upgrade_status.json" }

if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
}

# Status/phase tracking (Set-UpgradeRegistryValue, Get-UpgradeRegistryValue,
# Write-StatusJson, Set-Phase) used to be copy-pasted between this script and
# Start-TargetUpgrade.ps1 - they run as two separate processes with no shared
# runtime. Keeping the two copies in step by hand failed twice in practice:
# the per-stage monotonic percent clamp lived here for a while but not there,
# and the two Write-StatusJson field lists drifted apart, so
# D:\upgrade_status.json gained or lost keys depending on which script
# happened to write it last. They now live in OSUpgradeShared.ps1 and are
# dot-sourced by both, so a fix lands once.
#
# Placement is load-bearing. This MUST come after Write-Log above (the shared
# functions call it, and the two scripts deliberately log to different files)
# and after the $script:RegRoot / $script:StatusJson assignments above - the
# shared code reads both out of the caller's scope. Dot-sourcing runs the file
# in THIS scope, which is what makes that work; do not change it to '&'.
$script:SharedHelpers = Join-Path $PSScriptRoot "OSUpgradeShared.ps1"
if (-not (Test-Path $script:SharedHelpers)) {
    Write-Log "FATAL: required companion 'OSUpgradeShared.ps1' is missing from $PSScriptRoot - status cannot be tracked. Staging is incomplete; re-stage the Scripts folder from Server A." "ERROR"
    throw "Required companion 'OSUpgradeShared.ps1' was not found in $PSScriptRoot."
}
. $script:SharedHelpers

# Set by Set-Phase from Write-StatusJson's return value. Read further down to
# decide whether a TERMINAL status actually reached Server A before the
# monitoring scheduled tasks are torn down - initialised here so the checks
# below are never evaluating an undefined variable.
$script:StatusJsonPublished = $false

# =============================================================================
# Best-effort progress-percentage estimation
# =============================================================================
function Get-MoSetupVolatileProgress {
    <#
    Official Microsoft-documented registry key (Microsoft Learn: "Windows 10
    upgrade issues troubleshooting" - confirmed via docs search, not just a
    community claim): HKLM:\SYSTEM\Setup\mosetup\Volatile\SetupProgress - a
    REG_BINARY value in the range 0-100, present ONLY while Setup's engine is
    actively running. Per Microsoft: "Progress is tracked in the registry
    during the upgrade process using this key" - it spans ALL FOUR phases
    (Downlevel/SafeOS/First boot/Second boot) as ONE continuous, cumulative
    0-100 arc reaching 100% precisely at the end of Second Boot/OOBE - unlike
    ChildCompletion or setupact.log percentages, which are scoped/heuristic
    signals and are deliberately not used. This is the sole live Windows
    Setup percentage source.
    #>
    try {
        $val = (Get-ItemProperty "HKLM:\SYSTEM\Setup\mosetup\Volatile" -Name "SetupProgress" -ErrorAction SilentlyContinue).SetupProgress
        if ($null -eq $val) { return $null }
        # REG_BINARY comes back as a byte[] in PowerShell - the documented
        # value is a single byte 0-100; be defensive about representation.
        $n = if ($val -is [byte[]]) { [int]$val[0] } else { [int]$val }
        if ($n -ge 0 -and $n -le 100) { return $n }
        return $null
    } catch {
        return $null
    }
}

function Get-SetupProgressPercent {
    <#
    Reads only HKLM:\SYSTEM\Setup\mosetup\Volatile\SetupProgress, the
    Microsoft-documented overall progress counter spanning all Windows Setup
    phases. ChildCompletion and Panther percentages are intentionally excluded
    because they are scoped or heuristic and can make progress appear to jump.
    Returns $null when the authoritative counter is unavailable; callers carry
    forward the last verified sample without changing its timestamp.
    #>
    param([string]$LogPath)

    $moSetupPct = Get-MoSetupVolatileProgress
    if ($null -ne $moSetupPct) { return [pscustomobject]@{ Percent = $moSetupPct; Source = "MoSetupRegistry" } }
    return $null
}

function Get-SetupLogTail {
    param([string]$Path, [int]$Lines = 5, [int]$MaxChars = 800)
    try {
        if (-not (Test-Path $Path)) { return $null }
        $tail = Get-Content -Path $Path -Tail $Lines -ErrorAction SilentlyContinue
        if (-not $tail) { return $null }
        $text = ($tail -join " | ")
        if ($text.Length -gt $MaxChars) { $text = $text.Substring($text.Length - $MaxChars) }
        return $text
    } catch {
        return $null
    }
}

# =============================================================================
# Post-Upgrade Validation (Phase 7). Defined here - BEFORE the Main section -
# because PowerShell does not hoist function definitions; it must be defined
# before the point in the script where Main calls it.
# =============================================================================
function Invoke-PostUpgradeValidation {
    Write-Log "Running post-upgrade validation..."
    # Published BEFORE the work starts: the checks below (activation via
    # SoftwareLicensingProduct, then a full services comparison) can take
    # minutes, and without this the run looked finished but idle to Server A.
    Set-Phase -Phase 7 -PhaseName "Post-Upgrade Validation" -Status "InProgress" `
        -Notes "Windows Setup has finished and the new build has booted. Verifying build, edition, activation and services - the upgrade itself is no longer changing the system."
    $issues = @()
    $buildVerified = $false
    $buildNow = $null

    try {
        $buildNow = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop).CurrentBuildNumber
        $expectedBuild = Get-UpgradeRegistryValue -Name "TargetBuild"
        if (-not $expectedBuild -or -not $buildNow) {
            $issues += "Cannot verify target OS build: expected '$expectedBuild', found '$buildNow'."
        } elseif ($buildNow -ne $expectedBuild) {
            $issues += "Build mismatch: expected $expectedBuild, found $buildNow."
        } else {
            $buildVerified = $true
        }
        $osNow = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop

        # Edition retained? (Standard->Standard / Datacenter->Datacenter expected)
        $sourceEdition = Get-UpgradeRegistryValue -Name "SourceEditionId"
        $editionNow = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name EditionID -ErrorAction SilentlyContinue).EditionID
        if ($sourceEdition -and $editionNow -and $sourceEdition -ne $editionNow) {
            $issues += "Edition changed unexpectedly: source '$sourceEdition' vs current '$editionNow'."
        }

        # Licensing/activation - ALWAYS produce an explicit recommendation
        # (not just a warning when something's wrong) so the final summary
        # never silently omits activation status either way. Pre-upgrade
        # state was recorded (non-blockingly) by Start-TargetUpgrade.ps1's
        # own precheck - an unlicensed OS is a compliance concern, not a
        # reason to have stopped the upgrade itself.
        #
        # This script never activates the OS itself, and an in-place major-
        # version upgrade commonly resets/requires activation regardless of
        # prior state - so "was licensed, still licensed" carries little
        # real information, and would usually only happen coincidentally
        # (e.g. KMS/AD-Based Activation re-triggering fast after reboot).
        # The distinction that actually matters for the customer is: did
        # the UPGRADE ITSELF plausibly cause an activation regression (was
        # licensed before, isn't now - worth investigating), versus was it
        # already unlicensed beforehand (a pre-existing condition the
        # upgrade didn't cause - just needs the standard post-upgrade
        # activation step, same as any OS version change would).
        $preLicenseStatus = Get-UpgradeRegistryValue -Name "PreUpgradeLicenseStatus" -Default "Unknown"
        $lic = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" -ErrorAction Stop |
            Where-Object { $_.ApplicationID -eq '55c92734-d682-4d71-983e-d6ec3f16059f' -and $_.PartialProductKey -and $_.LicenseStatus -eq 1 }
        $postLicensed = [bool]$lic
        $licenseRecommendation =
            if ($postLicensed -and $preLicenseStatus -eq "Licensed") {
                "Licensed both before and after the upgrade. No action needed."
            } elseif ($postLicensed -and $preLicenseStatus -eq "NotLicensed") {
                "Was NOT Licensed before the upgrade but IS Licensed now (commonly auto-activated via KMS/AD-Based Activation after reboot). No action needed."
            } elseif ($postLicensed) {
                "Licensed post-upgrade (pre-upgrade activation state could not be determined). No action needed."
            } elseif ($preLicenseStatus -eq "Licensed") {
                "WAS Licensed before the upgrade but is NOT Licensed now - this MAY indicate the upgrade itself affected activation (e.g. hardware ID/license binding). RECOMMENDATION: investigate and re-activate Windows (KMS/MAK/slmgr) before closing this change."
            } elseif ($preLicenseStatus -eq "NotLicensed") {
                "Was NOT Licensed before the upgrade and remains NOT Licensed now - this is a PRE-EXISTING condition, not something the upgrade caused (in-place upgrades commonly require re-activation regardless of prior state). RECOMMENDATION: activate Windows (KMS/MAK/slmgr) as a standard part of closing this change."
            } else {
                "NOT Licensed post-upgrade (pre-upgrade activation state could not be determined). RECOMMENDATION: activate Windows (KMS/MAK/slmgr) before closing this change."
            }
        Set-UpgradeRegistryValue -Name "LicenseRecommendation" -Value $licenseRecommendation
        if (-not $postLicensed) { $issues += "OS activation: $licenseRecommendation" }

        # Basic critical services spot-check (tune per server class as needed).
        $criticalServices = @("RpcSs","EventLog","Winmgmt")
        foreach ($svcName in $criticalServices) {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if (-not $svc -or $svc.Status -ne "Running") { $issues += "Service '$svcName' not running post-upgrade." }
        }

        # Full services.msc comparison against the pre-upgrade snapshot (captured
        # by Start-TargetUpgrade.ps1 in the backup folder) - broader and more
        # useful for change-record evidence than the small hardcoded spot-check
        # above. Classifies every difference into ATTENTION (genuinely worth a
        # human look) vs INFORMATIONAL (expected/benign upgrade churn) instead
        # of flagging every raw difference equally - an in-place OS upgrade
        # routinely changes dozens of services (new OS-version services like
        # Edge Update/AppX components starting to appear, per-user "template"
        # services being re-instantiated under a new session suffix, on-demand
        # services simply not running at snapshot time) and treating all of
        # that as "RequiresAttention" trains reviewers to ignore the field
        # entirely. Only services that were genuinely Running+Automatic
        # (always-on) and are no longer running/present count as attention
        # items; everything else is recorded but explicitly labeled benign.
        try {
            $backupFolder = Get-UpgradeRegistryValue -Name "BackupFolder"
            $preSnapshotPath = Get-UpgradeRegistryValue -Name "PreUpgradeServicesSnapshot"
            if ($preSnapshotPath -and (Test-Path $preSnapshotPath) -and $backupFolder) {
                Set-Phase -Phase 7 -PhaseName "Post-Upgrade Validation" -Status "InProgress" `
                    -Notes "Build and activation checks done; comparing pre- and post-upgrade service inventory."
                $before = Import-Csv -Path $preSnapshotPath
                $after  = Get-Service | Select-Object Name, DisplayName, Status, StartType | Sort-Object Name
                $afterByName = @{}
                foreach ($s in $after) { $afterByName[$s.Name] = $s }

                # Well-known Windows components that legitimately self-manage
                # their own Status/StartType based on internal servicing/
                # update activity (e.g. TrustedInstaller's StartType is
                # documented to oscillate between Manual/Automatic depending
                # on whether servicing operations are pending) - never
                # attention-worthy on their own.
                $selfManagedServices = @("TrustedInstaller","wuauserv","WaaSMedicSvc","sppsvc","BITS","UsoSvc","LicenseManager")
                # Per-user "template" services are instantiated with a
                # per-session suffix (e.g. "CDPUserSvc_33a6c") that
                # regenerates on every logon/reboot - the underlying service
                # TEMPLATE still exists, only this specific instance's suffix
                # changed, so "removed" for these is a naming-convention
                # artifact, not a real absence.
                $perUserServicePattern = '_[0-9a-f]{4,8}$'

                $attentionLines = New-Object System.Collections.Generic.List[string]
                $infoLines      = New-Object System.Collections.Generic.List[string]

                foreach ($b in $before) {
                    $a = $afterByName[$b.Name]
                    $isPerUser     = $b.Name -match $perUserServicePattern
                    $isSelfManaged = $selfManagedServices -contains $b.Name
                    if (-not $a) {
                        $line = "REMOVED   : $($b.Name) ($($b.DisplayName)) - was $($b.Status)/$($b.StartType) before upgrade, service no longer present."
                        if ($isPerUser) {
                            $infoLines.Add("$line [benign - per-user service instance; suffix regenerates each session/reboot, underlying feature is unaffected]")
                        } elseif ($b.Status -eq "Running" -and $b.StartType -eq "Automatic") {
                            $attentionLines.Add($line)
                        } else {
                            $infoLines.Add("$line [low-risk - was $($b.StartType)/$($b.Status) before upgrade, not an always-on service]")
                        }
                    } elseif ($a.Status -ne $b.Status -or $a.StartType -ne $b.StartType) {
                        $line = "CHANGED   : $($b.Name) ($($b.DisplayName)) - before=$($b.Status)/$($b.StartType) -> after=$($a.Status)/$($a.StartType)"
                        $wentDown = ($b.Status -eq "Running" -and $a.Status -ne "Running")
                        if ($isSelfManaged) {
                            $infoLines.Add("$line [benign - Windows self-manages this service's state based on servicing/update activity]")
                        } elseif ($wentDown -and $b.StartType -eq "Automatic") {
                            $attentionLines.Add($line)
                        } else {
                            $infoLines.Add("$line [low-risk - Manual/on-demand service; normal for it to start/stop as needed]")
                        }
                    }
                }
                $newServices = $after | Where-Object { -not ($before.Name -contains $_.Name) }
                foreach ($n in $newServices) { $infoLines.Add("NEW       : $($n.Name) ($($n.DisplayName)) - $($n.Status)/$($n.StartType) [expected - introduced by the new OS version/roles]") }

                $requiresAttention = $attentionLines.Count -gt 0
                $reportPath = Join-Path $backupFolder "Services_PostUpgrade_Comparison.txt"
                $reportHeader = @(
                    "Services comparison - $env:COMPUTERNAME"
                    "Pre-upgrade snapshot : $preSnapshotPath"
                    "Compared at          : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                    "Result               : $(if ($requiresAttention) { 'RequiresAttention' } else { 'Consistent' })"
                    "Attention item(s)    : $($attentionLines.Count)"
                    "Informational/benign upgrade-related change(s): $($infoLines.Count)"
                    "----------------------------------------------------------------------"
                    "=== ATTENTION - review these ($($attentionLines.Count)) ==="
                )
                if ($attentionLines.Count -eq 0) { $reportHeader += "(none - no always-on/Automatic service unexpectedly stopped or disappeared)" }
                $infoHeader = @("", "=== INFORMATIONAL - expected upgrade-related churn, not a concern ($($infoLines.Count)) ===")
                if ($infoLines.Count -eq 0) { $infoHeader += "(none)" }
                ($reportHeader + $attentionLines + $infoHeader + $infoLines) | Out-File -FilePath $reportPath -Encoding UTF8 -Force

                Set-UpgradeRegistryValue -Name "ServicesComparisonReportPath" -Value $reportPath
                Set-UpgradeRegistryValue -Name "ServicesAttentionCount" -Value $attentionLines.Count -Type DWord
                Set-UpgradeRegistryValue -Name "ServicesInfoCount" -Value $infoLines.Count -Type DWord
                if ($requiresAttention) {
                    Set-UpgradeRegistryValue -Name "ServicesComparisonResult" -Value "RequiresAttention"
                    $issues += "Services comparison: $($attentionLines.Count) always-on service(s) unexpectedly stopped/removed post-upgrade (plus $($infoLines.Count) expected/benign change(s) - not a concern). See $reportPath."
                } else {
                    Set-UpgradeRegistryValue -Name "ServicesComparisonResult" -Value "Consistent"
                }
                Write-Log "Services comparison complete (Attention=$($attentionLines.Count), Informational=$($infoLines.Count)) -> $reportPath"
            } else {
                Write-Log "No pre-upgrade services snapshot found (BackupFolder/PreUpgradeServicesSnapshot registry values missing) - skipping services comparison." "WARN"
                Set-UpgradeRegistryValue -Name "ServicesComparisonResult" -Value "NotAvailable"
                $issues += "Services comparison unavailable: pre-upgrade snapshot or backup folder is missing."
            }
        } catch {
            Write-Log "Services comparison failed (non-blocking): $_" "WARN"
            Set-UpgradeRegistryValue -Name "ServicesComparisonResult" -Value "NotAvailable"
            $issues += "Services comparison failed: $_"
        }

        Set-UpgradeRegistryValue -Name "PostUpgradeOSCaption" -Value $osNow.Caption
    } catch {
        $issues += "Validation itself threw an error: $_"
    }

    Set-UpgradeRegistryValue -Name "PostUpgradeBuild" -Value ([string]$buildNow)
    Set-UpgradeRegistryValue -Name "PostUpgradeValidationTime" -Value ([DateTime]::UtcNow.ToString('o'))
    $validationResult = if (-not $buildVerified) { "Failed" } elseif ($issues.Count) { "PassedWithWarnings" } else { "Passed" }
    Set-UpgradeRegistryValue -Name "PostUpgradeValidationResult" -Value $validationResult
    if (-not $buildVerified) {
        Set-Phase -Phase 7 -PhaseName "Post-Upgrade Validation Failed" -Status "Failed" -PercentComplete 0 -Notes ("Target OS build was not verified. " + ($issues -join " | "))
    } elseif ($issues.Count -eq 0) {
        # 100% here is a VERIFIED fact (post-upgrade validation already
        # confirmed currentBuild -eq targetBuild locally), not a guess -
        # tag it "Measured" rather than the default "Estimated" for
        # consistency with removing every other fabricated placeholder.
        Set-Phase -Phase 7 -PhaseName "Completed" -Status "Completed" -PercentComplete 100 -PercentSource "Measured" -Notes "Post-upgrade validation passed."
    } else {
        Set-Phase -Phase 7 -PhaseName "Completed" -Status "CompletedWithWarnings" -PercentComplete 100 -PercentSource "Measured" -Notes ("Validation warnings: " + ($issues -join " | "))
    }
    if (-not $script:StatusJsonPublished) {
        Write-Log "Terminal registry status recorded; retaining monitor to retry status JSON publication." "WARN"
        return
    }
    Unregister-ScheduledTask -TaskName "OSUpgradePhaseMonitor" -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "OSUpgradeRebootWatcher" -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "OSUpgradeSetupLaunch" -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "Post-upgrade validation complete. Monitor tasks unregistered."
}

# =============================================================================
# Main
# =============================================================================
$currentBuild = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
$sourceBuild  = Get-UpgradeRegistryValue -Name "SourceBuild"
$targetBuild  = Get-UpgradeRegistryValue -Name "TargetBuild"
$lastPhase    = [int](Get-UpgradeRegistryValue -Name "Phase" -Default 0)
$lastStatus   = Get-UpgradeRegistryValue -Name "Status" -Default ""

Write-Log "Poll: currentBuild=$currentBuild sourceBuild=$sourceBuild targetBuild=$targetBuild lastPhase=$lastPhase lastStatus=$lastStatus"

# Terminal states - stop evaluating, unregister the recurring monitor/watcher.
if ($lastStatus -in @("Completed","CompletedWithWarnings","Failed") -and -not (Test-Path $script:MarkerRB)) {
    if (-not (Write-StatusJson)) {
        Write-Log "Terminal status JSON publication failed; retaining monitor for retry." "WARN"
        return
    }
    Write-Log "Already in terminal state '$lastStatus' - unregistering monitor/watcher tasks."
    Unregister-ScheduledTask -TaskName "OSUpgradePhaseMonitor" -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "OSUpgradeRebootWatcher" -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "OSUpgradeSetupLaunch" -Confirm:$false -ErrorAction SilentlyContinue
    return
}

# --- Rollback detection (setuprollback.cmd fired) -----------------------------
if (Test-Path $script:MarkerRB) {
    $setupDiagNote = ""
    try {
        $sdResults = Join-Path $env:WINDIR "Logs\SetupDiag\SetupDiagResults.xml"
        if (Test-Path $sdResults) {
            Copy-Item -Path $sdResults -Destination (Join-Path $script:LogDir "SetupDiagResults.xml") -Force -ErrorAction SilentlyContinue
            $setupDiagNote = " SetupDiag results copied to $script:LogDir\SetupDiagResults.xml."
        }
    } catch {
        Write-Log "Could not copy SetupDiag results (non-blocking): $_" "WARN"
    }
    Set-Phase -Phase 99 -PhaseName "Rolled Back" -Status "Failed" -PercentComplete 0 -Notes "setup.exe invoked /PostRollback - upgrade failed and system reverted to source OS.$setupDiagNote"
    if (-not $script:StatusJsonPublished) { return }
    Unregister-ScheduledTask -TaskName "OSUpgradePhaseMonitor" -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "OSUpgradeRebootWatcher" -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "OSUpgradeSetupLaunch" -Confirm:$false -ErrorAction SilentlyContinue
    return
}

if ($RebootEvent) {
    if ($lastStatus -eq "InProgress" -and $lastPhase -in @(3, 4)) {
        Set-UpgradeRegistryValue -Name "ExpectedDisconnect" -Value 1 -Type DWord
        Remove-ItemProperty -Path $script:RegRoot -Name "SetupMissingSinceUtc" -ErrorAction SilentlyContinue
        Set-Phase -Phase 4 -PhaseName "Safe OS Phase (pending/boot transition)" -Status "InProgress" `
            -Notes "Restart requested during Downlevel (Event ID 1074); Safe OS transition is inferred, not confirmed."
    }
    return
}

# --- OOBE-complete short-circuit (build-number-independent) ------------------
# BUG FIX (2026-08-26, real TestVM2 run): setupcomplete.cmd's /PostOOBE hook
# firing is an ABSOLUTE, unambiguous signal that Windows Setup has fully
# finished - regardless of what currentBuild vs. sourceBuild/targetBuild
# comparison says. Checked here, BEFORE the build-number branches below,
# because that comparison silently breaks when SourceBuild equals
# TargetBuild (e.g. a same-version test upgrade, or any genuine same-build
# refresh install): $currentBuild -eq $sourceBuild is then ALWAYS true, even
# long after the real upgrade finished, permanently trapping execution in
# the "still on old build" branch below (which returns) and never reaching
# the OOBE-marker check that already exists further down for the normal
# (differing-build) case. Section 1b already guarantees this marker is
# removed at the start of every fresh run, so its presence here can only
# mean THIS run's setupcomplete.cmd genuinely fired.
if ((Test-Path $script:MarkerOOBE) -and $lastPhase -le 7) {
    Set-UpgradeRegistryValue -Name "ExpectedDisconnect" -Value 0 -Type DWord
    Set-Phase -Phase 6 -PhaseName "Second Boot (OOBE) Phase" -Status "InProgress" -Notes "PostOOBE hook fired; finalizing configuration/cleanup."
    Invoke-PostUpgradeValidation
    return
}
# --- Still on the OLD build: Downlevel or Safe OS (blind window) -------------
if ($currentBuild -eq $sourceBuild) {
    $btPresent = Test-Path "$env:SystemDrive\`$WINDOWS.~BT"
    $setupProc = Get-Process -Name "setuphost","setupprep","setup" -ErrorAction SilentlyContinue

    if ($btPresent -and $setupProc) {
        Set-UpgradeRegistryValue -Name "SetupWasObserved" -Value 1 -Type DWord
        Set-UpgradeRegistryValue -Name "SetupLastObservedAtUtc" -Value ((Get-Date).ToUniversalTime().ToString("o"))
        Remove-ItemProperty -Path $script:RegRoot -Name "SetupMissingSinceUtc" -ErrorAction SilentlyContinue
        $logPath = "$env:SystemDrive\`$WINDOWS.~BT\Sources\Panther\setupact.log"
        $logTail = Get-SetupLogTail -Path $logPath
        if ($logTail) { Set-UpgradeRegistryValue -Name "SetupLogTail" -Value $logTail }
        $result = Get-SetupProgressPercent -LogPath $logPath
        if ($null -ne $result) {
            $pct = $result.Percent
            $pctSource = "Measured"
            Set-Phase -Phase 3 -PhaseName "Downlevel Phase" -Status "InProgress" -PercentComplete $pct -PercentSource $pctSource -Notes "setup.exe actively running on existing OS."
        } else {
            # No authoritative live measurement is available yet
            # (e.g. right at the very first poll after setup.exe launches,
            # before setupact.log/the mosetup registry key exist) - do NOT
            # fabricate an "Estimated" placeholder percentage here anymore
            # (customer feedback: a guessed number that later gets
            # superseded by a real one looks exactly like progress
            # regressing/resetting). Omitting -PercentComplete entirely
            # leaves the registry's last real value (from Phase 2's backup
            # step, or a prior real Downlevel reading) untouched instead.
            Set-Phase -Phase 3 -PhaseName "Downlevel Phase" -Status "InProgress" -Notes "setup.exe actively running on existing OS."
        }
    } elseif ($btPresent -and -not $setupProc) {
        $logPath = "$env:SystemDrive\`$WINDOWS.~BT\Sources\Panther\setuperr.log"
        $setupErrors = if (Test-Path $logPath) { Get-Content -Path $logPath -Tail 120 -ErrorAction SilentlyContinue } else { @() }
        $terminalSetupError = $setupErrors | Where-Object {
            $_ -match '(?i)User did not accept EULA|0xC190010E|SetupHost:.*failed|SetupHost:.*Result'
        } | Select-Object -Last 1
        if ($terminalSetupError) {
            Set-Phase -Phase 4 -PhaseName "Windows Setup Failed" -Status "Failed" -PercentComplete 0 `
                -Notes "Windows Setup exited before Safe OS: $terminalSetupError"
            return
        }
        $expectedDisconnect = [int](Get-UpgradeRegistryValue -Name "ExpectedDisconnect" -Default 0) -eq 1
        if ($expectedDisconnect) {
            Set-Phase -Phase 4 -PhaseName "Safe OS Phase (pending/boot transition)" -Status "InProgress" `
                -Notes "Setup process ended after Event ID 1074 requested a restart; disconnect is expected until First Boot."
            return
        }

        $setupWasObserved = [int](Get-UpgradeRegistryValue -Name "SetupWasObserved" -Default 0) -eq 1
        if (-not $setupWasObserved) {
            Set-Phase -Phase 3 -PhaseName "Downlevel Phase" -Status "InProgress" `
                -Notes "Setup artifacts exist, but this monitor has no prior process observation; waiting without inferring Safe OS or failure."
            return
        }

        $nowUtc = (Get-Date).ToUniversalTime()
        $missingSinceText = Get-UpgradeRegistryValue -Name "SetupMissingSinceUtc"
        if (-not $missingSinceText) {
            Set-UpgradeRegistryValue -Name "SetupMissingSinceUtc" -Value $nowUtc.ToString("o")
            Set-Phase -Phase 3 -PhaseName "Downlevel Phase (Setup process missing)" -Status "InProgress" `
                -Notes "Setup process is no longer present and no Event ID 1074 reboot evidence exists; starting the ten-minute confirmation window."
            return
        }

        try { $missingSinceUtc = [datetime]::Parse($missingSinceText).ToUniversalTime() } catch { $missingSinceUtc = $nowUtc }
        $missingMinutes = ($nowUtc - $missingSinceUtc).TotalMinutes
        if ($missingMinutes -ge 10) {
            $taskResult = "unavailable"
            try {
                $taskInfo = Get-ScheduledTaskInfo -TaskName "OSUpgradeSetupLaunch" -ErrorAction Stop
                if ($taskInfo) { $taskResult = $taskInfo.LastTaskResult }
            } catch {}
            $setupActTail = Get-SetupLogTail -Path "$env:SystemDrive\`$WINDOWS.~BT\Sources\Panther\setupact.log" -Lines 8 -MaxChars 1200
            $setupErrTail = Get-SetupLogTail -Path $logPath -Lines 8 -MaxChars 1200
            $lastObserved = Get-UpgradeRegistryValue -Name "SetupLastObservedAtUtc" -Default "unavailable"
            Set-Phase -Phase 4 -PhaseName "Windows Setup Failed" -Status "Failed" -PercentComplete 0 `
                -Notes ("Setup remained absent for {0:N1} minutes without Event ID 1074 reboot evidence. Last observed={1}; scheduled-task LastTaskResult={2}; setuperr tail={3}; setupact tail={4}" -f $missingMinutes, $lastObserved, $taskResult, $setupErrTail, $setupActTail)
            return
        }

        Set-Phase -Phase 3 -PhaseName "Downlevel Phase (Setup process missing)" -Status "InProgress" `
            -Notes ("Setup process remains absent without reboot evidence; failure confirmation window is {0:N1}/10 minutes." -f $missingMinutes)
    } else {
        Write-Log "On source build, no upgrade artifacts detected - leaving phase as-is ($lastPhase)."
    }
    return
}

# --- Now on the NEW build: First Boot / OOBE / Post-Upgrade Validation -------
if ($currentBuild -eq $targetBuild) {
    Set-UpgradeRegistryValue -Name "ExpectedDisconnect" -Value 0 -Type DWord
    Remove-ItemProperty -Path $script:RegRoot -Name "SetupMissingSinceUtc" -ErrorAction SilentlyContinue
    $setupInProgress  = (Get-ItemProperty "HKLM:\SYSTEM\Setup" -Name "SystemSetupInProgress" -ErrorAction SilentlyContinue).SystemSetupInProgress
    $oobeMarkerExists = Test-Path $script:MarkerOOBE

    if ($setupInProgress -eq 1 -and -not $oobeMarkerExists) {
        $logPath = Join-Path $env:WINDIR "Panther\setupact.log"
        $logTail = Get-SetupLogTail -Path $logPath
        if ($logTail) { Set-UpgradeRegistryValue -Name "SetupLogTail" -Value $logTail }
        $result = Get-SetupProgressPercent -LogPath $logPath
        if ($null -ne $result) {
            $pct = $result.Percent
            $pctSource = "Measured"
            Set-Phase -Phase 5 -PhaseName "First Boot Phase" -Status "InProgress" -PercentComplete $pct -PercentSource $pctSource -Notes "New OS booted; migrating roles/settings (SystemSetupInProgress=1)."
        } else {
            # Same reasoning as the Downlevel "no data yet" branch above - no
            # fabricated Estimated fallback; leave the last real percent
            # (from Downlevel, or a prior real First Boot reading) untouched.
            Set-Phase -Phase 5 -PhaseName "First Boot Phase" -Status "InProgress" -Notes "New OS booted; migrating roles/settings (SystemSetupInProgress=1)."
        }
    } elseif ($oobeMarkerExists -and $lastPhase -le 7) {
        # OOBE is a one-shot hook with no ongoing counter - omit
        # -PercentComplete so the last real First Boot reading (which can
        # already be close to 100% via the MoSetup registry) persists
        # instead of dropping to an artificial "95% OOBE milestone".
        Set-Phase -Phase 6 -PhaseName "Second Boot (OOBE) Phase" -Status "InProgress" -Notes "PostOOBE hook fired; finalizing configuration/cleanup."
        Invoke-PostUpgradeValidation
    } elseif ($setupInProgress -eq 0 -and -not $oobeMarkerExists) {
        # Setup finished per OS state but our hook never fired (media/switches differ) -
        # fall back to treating this as OOBE-complete so validation still runs.
        Set-Phase -Phase 6 -PhaseName "Second Boot (OOBE) Phase" -Status "InProgress" -Notes "SystemSetupInProgress=0 but PostOOBE marker missing - proceeding to validation as fallback."
        Invoke-PostUpgradeValidation
    } else {
        Write-Log "On target build, current phase $lastPhase unchanged - waiting."
    }
}
} finally {
    if ($ownsStatusMutex) { $statusMutex.ReleaseMutex() }
    $statusMutex.Dispose()
    if ($ownsStarterMutex) { $starterMutex.ReleaseMutex() }
    $starterMutex.Dispose()
}
