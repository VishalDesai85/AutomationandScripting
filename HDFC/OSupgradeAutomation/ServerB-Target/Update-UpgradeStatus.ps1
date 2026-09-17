<#
.SYNOPSIS
    Runs every minute and on startup events 12/6005 on Server B. Detects which
    phase of the in-place upgrade is active, reads Microsoft's MoSetup
    SetupProgress counter when available, and writes the result to BOTH the registry
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
    Phase 4 when restart initiation is observed (Event ID 1074). Numeric
    progress and its timestamp remain at the last verified SetupProgress
    sample until normal Windows services return. Server A's local mirror
    remains readable and marks its producer snapshot as carried forward.
#>

[CmdletBinding()]
param(
    [switch]$RebootInitiated
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
$script:StatusHelper = Join-Path $script:ScriptsDir "OSUpgradeStatus.ps1"

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

# =============================================================================
# Windows Setup progress telemetry
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
    ChildCompletion or the setupact.log regex scan, which are scoped/
    heuristic per-phase signals. This is the sole numeric source used by this
    status engine.
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
    Returns only Microsoft's documented MoSetup SetupProgress value. The
    ChildCompletion value and arbitrary percentage text in setupact.log are
    scoped implementation details and are not safe end-to-end counters.
    When SetupProgress is absent, the caller carries the last verified value
    and marks it stale instead of manufacturing a replacement percentage.
    #>
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

if (-not (Test-Path $script:StatusHelper)) {
    throw "Required shared status helper not found: $script:StatusHelper"
}
. $script:StatusHelper

# =============================================================================
# Post-Upgrade Validation (Phase 7). Defined here - BEFORE the Main section -
# because PowerShell does not hoist function definitions; it must be defined
# before the point in the script where Main calls it.
# =============================================================================
function Invoke-PostUpgradeValidation {
    Set-Phase -Phase 7 -PhaseName "Post-Upgrade Validation" -Status "InProgress" `
        -PercentComplete 100 -PercentSource "Measured" -ProgressSource "StageBoundary.Validation" -ProgressFreshness "Milestone" `
        -Notes "Windows Setup completed; validating build, edition, activation, services, and retained configuration."
    Write-Log "Running post-upgrade validation..."
    $issues = @()

    try {
        $osNow = Get-CimInstance Win32_OperatingSystem
        $buildNow = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber
        if ($targetBuild -and $buildNow -ne $targetBuild) {
            $issues += "Build mismatch: expected $targetBuild, found $buildNow."
        }

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
        $lic = Get-CimInstance SoftwareLicensingProduct -ErrorAction SilentlyContinue |
            Where-Object { $_.PartialProductKey -and $_.LicenseStatus -eq 1 }
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
            }
        } catch {
            Write-Log "Services comparison failed (non-blocking): $_" "WARN"
            Set-UpgradeRegistryValue -Name "ServicesComparisonResult" -Value "NotAvailable"
        }

        Set-UpgradeRegistryValue -Name "PostUpgradeOSCaption" -Value $osNow.Caption
    } catch {
        $issues += "Validation itself threw an error: $_"
    }

    if ($issues.Count -eq 0) {
        # 100% here is a VERIFIED fact (post-upgrade validation already
        # confirmed currentBuild -eq targetBuild locally), not a guess -
        # tag it "Measured" rather than the default "Estimated" for
        # consistency with removing every other fabricated placeholder.
        Set-Phase -Phase 7 -PhaseName "Completed" -Status "Completed" -PercentComplete 100 -PercentSource "Measured" `
            -ProgressSource "PostUpgradeValidation" -ProgressFreshness "Terminal" -Notes "Post-upgrade validation passed."
    } else {
        Set-Phase -Phase 7 -PhaseName "Completed" -Status "CompletedWithWarnings" -PercentComplete 100 -PercentSource "Measured" `
            -ProgressSource "PostUpgradeValidation" -ProgressFreshness "Terminal" -Notes ("Validation warnings: " + ($issues -join " | "))
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
$bootChanged  = Update-UpgradeBootEvidence

Write-Log "Poll: currentBuild=$currentBuild sourceBuild=$sourceBuild targetBuild=$targetBuild lastPhase=$lastPhase lastStatus=$lastStatus bootChanged=$bootChanged"

if ($RebootInitiated) {
    Set-Phase -Phase 4 -PhaseName "Safe OS Phase (reboot initiated)" -Status "InProgress" `
        -ProgressSource "EventLog.User32.1074" -ProgressFreshness "CarriedForward" `
        -Notes "Windows restart initiation detected through System event 1074. The last verified SetupProgress value is retained during the WinPE telemetry outage."
    return
}

# Terminal states - stop evaluating, unregister the recurring monitor/watcher.
if ($lastStatus -in @("Completed","CompletedWithWarnings","Failed") -and -not (Test-Path $script:MarkerRB)) {
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
    Set-Phase -Phase 99 -PhaseName "Rolled Back" -Status "Failed" `
        -ProgressSource "WindowsSetup.PostRollback" -ProgressFreshness "Terminal" `
        -Notes "setup.exe invoked /PostRollback - upgrade failed and system reverted to source OS.$setupDiagNote"
    Unregister-ScheduledTask -TaskName "OSUpgradePhaseMonitor" -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "OSUpgradeSetupLaunch" -Confirm:$false -ErrorAction SilentlyContinue
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
if ((Test-Path $script:MarkerOOBE) -and $lastStatus -notin @("Completed", "CompletedWithWarnings", "Failed")) {
    if ($lastPhase -lt 7) {
        Set-Phase -Phase 6 -PhaseName "Second Boot (OOBE) Phase" -Status "InProgress" `
            -PercentComplete 100 -PercentSource "Measured" -ProgressSource "WindowsSetup.PostOOBE" -ProgressFreshness "Milestone" `
            -Notes "PostOOBE hook fired; finalizing configuration/cleanup."
    } else {
        Write-Log "Resuming interrupted post-upgrade validation from Phase $lastPhase."
    }
    Invoke-PostUpgradeValidation
    return
}

# --- Still on the OLD build: Downlevel or Safe OS (blind window) -------------
if ($currentBuild -eq $sourceBuild) {
    $btPresent = Test-Path "$env:SystemDrive\`$WINDOWS.~BT"
    $setupProc = Get-Process -Name "setuphost","setupprep","setup" -ErrorAction SilentlyContinue

    if ($setupProc) {
        Remove-ItemProperty -Path $script:RegRoot -Name "SetupProcessMissingSinceUtc" -ErrorAction SilentlyContinue
        $logPath = "$env:SystemDrive\`$WINDOWS.~BT\Sources\Panther\setupact.log"
        $logTail = Get-SetupLogTail -Path $logPath
        if ($logTail) { Set-UpgradeRegistryValue -Name "SetupLogTail" -Value $logTail }
        $result = Get-SetupProgressPercent
        if ($null -ne $result) {
            Set-UpgradeRegistryValue -Name "SetupTelemetryPercent" -Value $result.Percent -Type DWord
            Set-UpgradeRegistryValue -Name "SetupTelemetrySource" -Value "MoSetup.SetupProgress"
            Set-Phase -Phase 3 -PhaseName "Downlevel Phase" -Status "InProgress" `
                -PercentComplete $result.Percent -PercentSource "Measured" -ProgressSource "MoSetup.SetupProgress" -ProgressFreshness "Live" `
                -Notes "Windows Setup is actively running on the source OS; progress is from MoSetup SetupProgress."
        } else {
            Set-Phase -Phase 3 -PhaseName "Downlevel Phase" -Status "InProgress" `
                -ProgressSource "MoSetup.SetupProgress" -ProgressFreshness "CarriedForward" `
                -Notes "Windows Setup is running, but MoSetup SetupProgress is currently unavailable; retaining the last verified value."
        }
    } elseif ($lastPhase -eq 4 -or [bool][int](Get-UpgradeRegistryValue -Name "ExpectedDisconnect" -Default 0)) {
        Set-Phase -Phase 4 -PhaseName "Safe OS Phase (pending/boot transition)" -Status "InProgress" `
            -ProgressSource "EventLog.User32.1074" -ProgressFreshness "CarriedForward" `
            -Notes "A restart was explicitly observed; retaining the last verified SetupProgress value while SafeOS/WinPE is unreachable."
    } else {
        $nowUtc = [DateTimeOffset]::UtcNow
        $missingSinceUtc = Get-UpgradeRegistryValue -Name "SetupProcessMissingSinceUtc"
        if (-not $missingSinceUtc) {
            $missingSinceUtc = $nowUtc.ToString("o")
            Set-UpgradeRegistryValue -Name "SetupProcessMissingSinceUtc" -Value $missingSinceUtc
        }
        try {
            $missingMinutes = ($nowUtc - [DateTimeOffset]::Parse($missingSinceUtc)).TotalMinutes
        } catch {
            $missingMinutes = 0
            Set-UpgradeRegistryValue -Name "SetupProcessMissingSinceUtc" -Value $nowUtc.ToString("o")
        }

        if ($missingMinutes -ge 10) {
            $taskInfo = Get-ScheduledTaskInfo -TaskName "OSUpgradeSetupLaunch" -ErrorAction SilentlyContinue
            $taskResult = if ($taskInfo) { $taskInfo.LastTaskResult } else { "unavailable" }
            $artifactNote = if ($btPresent) { "Windows setup artifacts exist." } else { "Windows setup artifacts were not created." }
            Set-UpgradeRegistryValue -Name "SetupFailureDetectedAtUtc" -Value $nowUtc.ToString("o")
            Set-Phase -Phase 3 -PhaseName "Windows Setup Stopped Before Reboot" -Status "Failed" `
                -ProgressSource "SetupProcessLiveness" -ProgressFreshness "Terminal" `
                -Notes "No Windows Setup process or Event 1074 reboot evidence was observed for $([math]::Round($missingMinutes, 1)) minutes. $artifactNote Scheduled task LastTaskResult=$taskResult. Review Panther setupact.log/setuperr.log."
            Unregister-ScheduledTask -TaskName "OSUpgradeRebootWatcher" -Confirm:$false -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName "OSUpgradeSetupLaunch" -Confirm:$false -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName "OSUpgradePhaseMonitor" -Confirm:$false -ErrorAction SilentlyContinue
        } else {
            Set-Phase -Phase 3 -PhaseName "Downlevel Phase" -Status "InProgress" `
                -ProgressSource "SetupProcessLiveness" -ProgressFreshness "CarriedForward" `
                -Notes "Windows Setup is temporarily not resident and no restart event has been observed; waiting up to 10 minutes before declaring a stopped Setup process."
        }
    }
    return
}

# --- Now on the NEW build: First Boot / OOBE / Post-Upgrade Validation -------
if ($currentBuild -eq $targetBuild) {
    $setupInProgress  = (Get-ItemProperty "HKLM:\SYSTEM\Setup" -Name "SystemSetupInProgress" -ErrorAction SilentlyContinue).SystemSetupInProgress
    $oobeMarkerExists = Test-Path $script:MarkerOOBE

    if ($setupInProgress -eq 1 -and -not $oobeMarkerExists) {
        Remove-ItemProperty -Path $script:RegRoot -Name "SetupProcessMissingSinceUtc" -ErrorAction SilentlyContinue
        $logPath = Join-Path $env:WINDIR "Panther\setupact.log"
        $logTail = Get-SetupLogTail -Path $logPath
        if ($logTail) { Set-UpgradeRegistryValue -Name "SetupLogTail" -Value $logTail }
        $result = Get-SetupProgressPercent
        if ($null -ne $result) {
            Set-UpgradeRegistryValue -Name "SetupTelemetryPercent" -Value $result.Percent -Type DWord
            Set-UpgradeRegistryValue -Name "SetupTelemetrySource" -Value "MoSetup.SetupProgress"
            Set-Phase -Phase 5 -PhaseName "First Boot Phase" -Status "InProgress" `
                -PercentComplete $result.Percent -PercentSource "Measured" -ProgressSource "MoSetup.SetupProgress" -ProgressFreshness "Live" `
                -Notes "New OS booted; migrating roles/settings (SystemSetupInProgress=1)."
        } else {
            Set-Phase -Phase 5 -PhaseName "First Boot Phase" -Status "InProgress" `
                -ProgressSource "MoSetup.SetupProgress" -ProgressFreshness "CarriedForward" `
                -Notes "New OS booted and Setup is active, but MoSetup SetupProgress is unavailable; retaining the last verified value."
        }
    } elseif ($oobeMarkerExists -and $lastPhase -lt 7) {
        Set-Phase -Phase 6 -PhaseName "Second Boot (OOBE) Phase" -Status "InProgress" `
            -PercentComplete 100 -PercentSource "Measured" -ProgressSource "WindowsSetup.PostOOBE" -ProgressFreshness "Milestone" `
            -Notes "PostOOBE hook fired; finalizing configuration/cleanup."
        Invoke-PostUpgradeValidation
    } elseif ($setupInProgress -eq 0 -and -not $oobeMarkerExists) {
        # Setup finished per OS state but our hook never fired (media/switches differ) -
        # fall back to treating this as OOBE-complete so validation still runs.
        Set-Phase -Phase 6 -PhaseName "Second Boot (OOBE) Phase" -Status "InProgress" `
            -PercentComplete 100 -PercentSource "Measured" -ProgressSource "SystemSetupInProgress" -ProgressFreshness "Milestone" `
            -Notes "SystemSetupInProgress=0 but PostOOBE marker is missing; proceeding to validation using local OS state."
        Invoke-PostUpgradeValidation
    } else {
        Write-Log "On target build, current phase $lastPhase unchanged - waiting."
    }
}
