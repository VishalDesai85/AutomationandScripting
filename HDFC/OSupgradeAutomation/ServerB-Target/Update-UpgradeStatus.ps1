<#
.SYNOPSIS
    Runs on a schedule (every 5 minutes, registered by Start-TargetUpgrade.ps1)
    on Server B. Detects which phase of the in-place upgrade is currently
    active, estimates a progress percentage by parsing Windows Setup's own
    Panther logs / registry, and writes the result to BOTH the registry
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
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# --- Shared constants (must match Start-TargetUpgrade.ps1) -------------------
$script:RegRoot     = "HKLM:\SOFTWARE\OSUpgradeAutomation"
$script:BaseDir     = "C:\ProgramData\OSUpgradeAutomation"
$script:ScriptsDir  = Join-Path $script:BaseDir "Scripts"
$script:LogDir      = Join-Path $script:BaseDir "Logs"
$script:MarkerOOBE  = Join-Path $script:BaseDir "postoobe.marker"
$script:MarkerRB    = Join-Path $script:BaseDir "rollback.marker"
$script:LogFile     = Join-Path $script:LogDir "Update-UpgradeStatus.log"

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

function Set-UpgradeRegistryValue {
    param([string]$Name, $Value, [string]$Type = "String")
    if (-not (Test-Path $script:RegRoot)) { New-Item -Path $script:RegRoot -Force | Out-Null }
    New-ItemProperty -Path $script:RegRoot -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Get-UpgradeRegistryValue {
    param([string]$Name, $Default = $null)
    if (Test-Path $script:RegRoot) {
        $v = (Get-ItemProperty -Path $script:RegRoot -Name $Name -ErrorAction SilentlyContinue).$Name
        if ($null -ne $v) { return $v }
    }
    return $Default
}

function Write-StatusJson {
    param([hashtable]$Extra = @{})
    try {
        $obj = [ordered]@{
            ComputerName    = $env:COMPUTERNAME
            Phase           = Get-UpgradeRegistryValue -Name "Phase"
            PhaseName       = Get-UpgradeRegistryValue -Name "PhaseName"
            Status          = Get-UpgradeRegistryValue -Name "Status"
            PercentComplete = Get-UpgradeRegistryValue -Name "PercentComplete"
            PercentSource   = Get-UpgradeRegistryValue -Name "PercentSource"
            SourceBuild     = Get-UpgradeRegistryValue -Name "SourceBuild"
            TargetBuild     = Get-UpgradeRegistryValue -Name "TargetBuild"
            StartTime       = Get-UpgradeRegistryValue -Name "StartTime"
            LastUpdated     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            Notes           = Get-UpgradeRegistryValue -Name "Notes"
            SetupLogTail    = Get-UpgradeRegistryValue -Name "SetupLogTail"
            PostUpgradeOSCaption         = Get-UpgradeRegistryValue -Name "PostUpgradeOSCaption"
            ServicesComparisonResult     = Get-UpgradeRegistryValue -Name "ServicesComparisonResult"
            ServicesComparisonReportPath = Get-UpgradeRegistryValue -Name "ServicesComparisonReportPath"
            ServicesAttentionCount       = Get-UpgradeRegistryValue -Name "ServicesAttentionCount"
            ServicesInfoCount            = Get-UpgradeRegistryValue -Name "ServicesInfoCount"
            TargetOSCaption              = Get-UpgradeRegistryValue -Name "TargetOSCaption"
            LicenseRecommendation        = Get-UpgradeRegistryValue -Name "LicenseRecommendation"
            Stage                        = Get-UpgradeRegistryValue -Name "Stage"
        }
        foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] }
        $tmp = "$($script:StatusJson).tmp"
        ($obj | ConvertTo-Json -Depth 4) | Out-File -FilePath $tmp -Encoding UTF8 -Force
        Move-Item -Path $tmp -Destination $script:StatusJson -Force
    } catch {
        Write-Log "Non-blocking: failed to write status JSON: $_" "WARN"
    }
}

function Set-Phase {
    param(
        [int]$Phase, [string]$PhaseName, [string]$Status = "InProgress", [int]$PercentComplete = -1, [string]$Notes = "",
        # "Measured" = derived from a real, live data source (regex-parsed
        # from setupact.log); "Estimated" (default) = a best-effort milestone
        # marker where no live telemetry source exists (Safe OS/WinPE blind
        # window, or the one-shot OOBE hook). Callers below pass "Measured"
        # explicitly only where Get-SetupProgressPercent actually found a
        # real value to parse.
        [ValidateSet("Measured","Estimated")][string]$PercentSource = "Estimated"
    )
    # Stage grouping for customer-facing display: Stage 1/2 are OUR OWN
    # script's work (prechecks/backup); Stage 3 is Windows Setup's own
    # engine actually running (Downlevel through Completed/RolledBack) -
    # this distinction is what the customer asked to see called out clearly.
    $stageLabel = switch ($Phase) {
        1       { "Stage 1/3: Pre-Upgrade Assessment" }
        2       { "Stage 2/3: Backup" }
        99      { "Stage 3/3: Windows Setup Execution (Rolled Back)" }
        default { "Stage 3/3: Windows Setup Execution" }
    }
    Set-UpgradeRegistryValue -Name "Stage"       -Value $stageLabel
    Set-UpgradeRegistryValue -Name "Phase"       -Value $Phase -Type DWord
    Set-UpgradeRegistryValue -Name "PhaseName"   -Value $PhaseName
    Set-UpgradeRegistryValue -Name "Status"      -Value $Status
    Set-UpgradeRegistryValue -Name "LastUpdated" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    if ($PercentComplete -ge 0) {
        # Never let the displayed percentage visibly regress while a run is
        # still InProgress. Start-TargetUpgrade.ps1 writes an initial
        # placeholder the moment it hands off to setup.exe; moments later
        # Windows Setup's OWN internal progress counter (parsed from
        # setupact.log) takes over - but that counter tracks Setup's own
        # separate task list from scratch, so it can legitimately report a
        # LOWER number early on. Without this clamp, swapping from one scale
        # to the other looks like progress went backwards. Deliberately NOT
        # applied to terminal statuses (Failed/RolledBack correctly reports
        # 0%, not a clamped-up stale high-water mark).
        # SCOPED TO STAGE, NOT GLOBAL (2026-07-24): Stage 1/2 now have their
        # OWN task-count-based percentage, independent of Stage 3's telemetry
        # arc - clamping against a PRIOR stage's ending value would wrongly
        # force Stage 3's genuinely-lower first real reading (e.g. Downlevel
        # starting at 15% Measured) up to Stage 2's ending 100%. Only clamp
        # when the stored percent came from THIS SAME stage.
        if ($Status -eq "InProgress" -and (Get-UpgradeRegistryValue -Name "PercentStage") -eq $stageLabel) {
            $priorPercent = [int](Get-UpgradeRegistryValue -Name "PercentComplete" -Default 0)
            $PercentComplete = [math]::Max($PercentComplete, $priorPercent)
        }
        Set-UpgradeRegistryValue -Name "PercentComplete" -Value $PercentComplete -Type DWord
        Set-UpgradeRegistryValue -Name "PercentSource"   -Value $PercentSource
        Set-UpgradeRegistryValue -Name "PercentStage"    -Value $stageLabel
    } elseif ((Get-UpgradeRegistryValue -Name "PercentStage") -and (Get-UpgradeRegistryValue -Name "PercentStage") -ne $stageLabel) {
        # BUG FIX (2026-08-26, real TestVM2 run): entering a NEW stage with no
        # fresh measurement yet used to leave the PREVIOUS stage's ending
        # PercentComplete/PercentSource sitting untouched in the registry -
        # already correctly hidden from the console log below via the
        # $displayPct stage-match check, but Write-StatusJson and the
        # orchestrator's CIM/DCOM registry read both consume the RAW
        # registry values directly, so they kept showing e.g. "100%
        # Measured" (Stage 2's ending backup percent) mislabeled under the
        # brand-new Stage 3/Downlevel Phase - looking like Setup was already
        # done when it had barely started. Clear the stale values here so
        # every channel (console, JSON, CIM/DCOM) agrees there is no
        # measurement yet for this stage.
        Remove-ItemProperty -Path $script:RegRoot -Name "PercentComplete" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $script:RegRoot -Name "PercentSource" -ErrorAction SilentlyContinue
        Set-UpgradeRegistryValue -Name "PercentStage" -Value $stageLabel
    }
    if ($Notes) { Set-UpgradeRegistryValue -Name "Notes" -Value $Notes }
    # Callers can now omit -PercentComplete entirely (leaving it at the -1
    # default) for phases where NO real measurement exists (Safe OS/WinPE,
    # the OOBE hook, or a "no telemetry yet" fallback) instead of writing a
    # fabricated "Estimated" milestone number - customer feedback was that
    # seeing an invented placeholder percentage look like real regressed/
    # reset progress. When omitted, resolve what to DISPLAY (log text only -
    # the registry itself is simply left untouched above) from whatever the
    # last REAL value already in the registry was, so the log/JSON/GUI keep
    # showing the last genuine reading instead of a fake number or a "-1".
    # BUG FIX (2026-07-20): the fallback below used to default to a
    # hardcoded 0/"Estimated" when nothing was stored yet - which, on
    # Phase 1's very first call ever (fresh registry, nothing to carry
    # forward), reconstructed the exact same "Percent=0 (Estimated)" text
    # the whole point of omitting -PercentComplete was meant to eliminate.
    # Now distinguishes "no real value EVER existed" ($null - show nothing)
    # from "a real value exists to carry forward" (show it).
    $storedPct    = Get-UpgradeRegistryValue -Name "PercentComplete"
    $storedSource = Get-UpgradeRegistryValue -Name "PercentSource"
    $storedStage  = Get-UpgradeRegistryValue -Name "PercentStage"
    if ($PercentComplete -ge 0) {
        $displayPct    = $PercentComplete
        $displaySource = $PercentSource
    } elseif ($null -ne $storedPct -and $storedStage -eq $stageLabel) {
        # Only carry forward a stored value that belongs to THIS SAME stage
        # (2026-07-24) - see the matching comment in Start-TargetUpgrade.ps1's
        # Set-Phase for why (avoids a prior stage's ending percent flashing
        # on screen for one call before the new stage's own real percent
        # overwrites it). Within Stage 3 itself (Phases 3-7/99 all share the
        # same stageLabel) this is a no-op - carry-forward across those
        # phases continues exactly as before.
        $displayPct    = $storedPct
        $displaySource = if ($storedSource) { $storedSource } else { "Estimated" }
    } else {
        $displayPct = $null
    }
    $pctClause = if ($null -ne $displayPct) { " Percent=$displayPct ($displaySource)" } else { "" }
    # Dropped the bare "Phase=$Phase" number from this text (2026-07-20,
    # customer feedback: it visually looked redundant/confusable next to
    # "Stage 3/3" - two different numbering schemes that don't actually
    # correlate 1:1, since Phase 3-7 and 99 ALL map to the same Stage 3/3).
    # The raw Phase number is still fully preserved in the registry/JSON for
    # technical/ServiceNow use - just no longer restated in this text.
    Write-Log "[$stageLabel] $PhaseName - Status=$Status$pctClause $Notes"
    Write-StatusJson

    # Mirror the same phase/percent line into a second, durable copy inside
    # the change's own D:\UpgradeBackup\<run> folder - unlike
    # C:\ProgramData\OSUpgradeAutomation\Logs (purged by
    # Remove-UpgradeArtifacts.ps1 after -RetentionDays), that backup folder
    # is intentionally never auto-deleted, so this becomes the durable
    # end-to-end record of exactly how long each phase took, from Downlevel
    # through Completed/Rolled Back - or exactly which phase it failed at.
    try {
        $backupFolder = Get-UpgradeRegistryValue -Name "BackupFolder"
        if ($backupFolder -and (Test-Path $backupFolder)) {
            $progressLine = "[{0}] [{1}] Phase={2} ({3}) Status={4}{5} {6}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $stageLabel, $Phase, $PhaseName, $Status, $pctClause, $Notes
            Add-Content -Path (Join-Path $backupFolder "OSUpgradeProgress.log") -Value $progressLine -Encoding UTF8
        }
    } catch {
        Write-Log "Non-blocking: failed to mirror progress line to D:\UpgradeBackup: $_" "WARN"
    }
}

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
    ChildCompletion or the setupact.log regex scan, which are scoped/
    heuristic per-phase signals. This is the single most authoritative live
    source available and is tried FIRST.
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
    Tries, in order:
      1. HKLM:\SYSTEM\Setup\mosetup\Volatile\SetupProgress (REG_BINARY) - the
         OFFICIAL Microsoft-documented overall progress counter, spanning all
         four phases as one continuous arc (see Get-MoSetupVolatileProgress).
         When this answers, it is returned as-is with Source="MoSetupRegistry"
         and should NOT be phase-clamped by the caller - it's already the
         authoritative overall percentage.
      2. HKLM:\SYSTEM\Setup\Status\ChildCompletion\setup.exe (DWORD) - an
         undocumented-but-widely-observed value Windows Setup itself updates
         with an overall completion percentage during the engine phases.
      3. Regex scan of the tail of setupact.log for the highest "NN%" value
         found near lines mentioning progress.
      Returns $null if none of the three sources yield a usable number
      (caller should fall back to a phase-based estimate). Otherwise returns
      a [pscustomobject]@{ Percent; Source } so the caller can tell an
      authoritative cross-phase reading apart from a scoped/heuristic one.
    #>
    param([string]$LogPath)

    $moSetupPct = Get-MoSetupVolatileProgress
    if ($null -ne $moSetupPct) { return [pscustomobject]@{ Percent = $moSetupPct; Source = "MoSetupRegistry" } }

    try {
        $val = (Get-ItemProperty "HKLM:\SYSTEM\Setup\Status\ChildCompletion" -Name "setup.exe" -ErrorAction SilentlyContinue)."setup.exe"
        if ($null -ne $val -and $val -is [int] -and $val -ge 0 -and $val -le 100) { return [pscustomobject]@{ Percent = [int]$val; Source = "ChildCompletion" } }
    } catch {}

    try {
        if ($LogPath -and (Test-Path $LogPath)) {
            $tail = Get-Content -Path $LogPath -Tail 200 -ErrorAction SilentlyContinue
            $best = -1
            foreach ($line in $tail) {
                if ($line -match '(?i)progress.*?(\d{1,3})\s*%') {
                    $n = [int]$Matches[1]
                    if ($n -gt $best -and $n -le 100) { $best = $n }
                }
            }
            if ($best -ge 0) { return [pscustomobject]@{ Percent = $best; Source = "SetupActLog" } }
        }
    } catch {}

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
        Set-Phase -Phase 7 -PhaseName "Completed" -Status "Completed" -PercentComplete 100 -PercentSource "Measured" -Notes "Post-upgrade validation passed."
    } else {
        Set-Phase -Phase 7 -PhaseName "Completed" -Status "CompletedWithWarnings" -PercentComplete 100 -PercentSource "Measured" -Notes ("Validation warnings: " + ($issues -join " | "))
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
if ((Test-Path $script:MarkerOOBE) -and $lastPhase -lt 7) {
    Set-Phase -Phase 6 -PhaseName "Second Boot (OOBE) Phase" -Status "InProgress" -Notes "PostOOBE hook fired; finalizing configuration/cleanup."
    Invoke-PostUpgradeValidation
    return
}

# --- Still on the OLD build: Downlevel or Safe OS (blind window) -------------
if ($currentBuild -eq $sourceBuild) {
    $btPresent = Test-Path "$env:SystemDrive\`$WINDOWS.~BT"
    $setupProc = Get-Process -Name "setuphost","setupprep","setup" -ErrorAction SilentlyContinue

    if ($btPresent -and $setupProc) {
        $logPath = "$env:SystemDrive\`$WINDOWS.~BT\Sources\Panther\setupact.log"
        $logTail = Get-SetupLogTail -Path $logPath
        if ($logTail) { Set-UpgradeRegistryValue -Name "SetupLogTail" -Value $logTail }
        $result = Get-SetupProgressPercent -LogPath $logPath
        if ($null -ne $result) {
            # The official MoSetup registry counter is already the
            # authoritative OVERALL percentage across all 4 phases - do NOT
            # phase-clamp it. The less authoritative sources (ChildCompletion/
            # setupact.log regex) are scoped/heuristic, so keep the existing
            # 55% ceiling for those to avoid over-stating Downlevel progress.
            $pct = if ($result.Source -eq "MoSetupRegistry") { $result.Percent } else { [math]::Min($result.Percent, 55) }
            $pctSource = "Measured"
            Set-Phase -Phase 3 -PhaseName "Downlevel Phase" -Status "InProgress" -PercentComplete $pct -PercentSource $pctSource -Notes "setup.exe actively running on existing OS."
        } else {
            # No real measurement available yet from ANY of the 3 sources
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
        # No telemetry can exist here by definition (about to reboot into
        # WinPE) - omit -PercentComplete so the last real Downlevel reading
        # (often already well past 55%, sometimes near 100% via the
        # MoSetup registry) keeps showing instead of dropping to an
        # artificial, LOWER "Safe OS milestone" that looks like a regression.
        Set-Phase -Phase 4 -PhaseName "Safe OS Phase (pending/boot transition)" -Status "InProgress" `
            -Notes "Setup image staged; process not resident - machine likely rebooting into Safe OS/WinPE. No heartbeat expected until First Boot."
    } else {
        Write-Log "On source build, no upgrade artifacts detected - leaving phase as-is ($lastPhase)."
    }
    return
}

# --- Now on the NEW build: First Boot / OOBE / Post-Upgrade Validation -------
if ($currentBuild -eq $targetBuild) {
    $setupInProgress  = (Get-ItemProperty "HKLM:\SYSTEM\Setup" -Name "SystemSetupInProgress" -ErrorAction SilentlyContinue).SystemSetupInProgress
    $oobeMarkerExists = Test-Path $script:MarkerOOBE

    if ($setupInProgress -eq 1 -and -not $oobeMarkerExists) {
        $logPath = Join-Path $env:WINDIR "Panther\setupact.log"
        $logTail = Get-SetupLogTail -Path $logPath
        if ($logTail) { Set-UpgradeRegistryValue -Name "SetupLogTail" -Value $logTail }
        $result = Get-SetupProgressPercent -LogPath $logPath
        if ($null -ne $result) {
            $pct = if ($result.Source -eq "MoSetupRegistry") { $result.Percent } else { [math]::Max($result.Percent, 60) }
            $pctSource = "Measured"
            Set-Phase -Phase 5 -PhaseName "First Boot Phase" -Status "InProgress" -PercentComplete $pct -PercentSource $pctSource -Notes "New OS booted; migrating roles/settings (SystemSetupInProgress=1)."
        } else {
            # Same reasoning as the Downlevel "no data yet" branch above - no
            # fabricated Estimated fallback; leave the last real percent
            # (from Downlevel, or a prior real First Boot reading) untouched.
            Set-Phase -Phase 5 -PhaseName "First Boot Phase" -Status "InProgress" -Notes "New OS booted; migrating roles/settings (SystemSetupInProgress=1)."
        }
    } elseif ($oobeMarkerExists -and $lastPhase -lt 7) {
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
