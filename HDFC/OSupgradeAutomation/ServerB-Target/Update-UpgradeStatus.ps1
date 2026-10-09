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
    normally runs there in this solution. Event 1074 records a restart request,
    not proof of Safe OS. Current-run Panther execution events recover Safe OS
    and short First Boot phases retrospectively when Windows services return.
    Numeric progress is phase-scoped; Downlevel 100 is not Setup completion.
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
    # Setup can reach 100 before the first reboot; never use it as completion proof.
    try {
        $val = (Get-ItemProperty "HKLM:\SYSTEM\Setup\mosetup\Volatile" -Name "SetupProgress" -ErrorAction SilentlyContinue).SetupProgress
        if ($null -eq $val) { return $null }
        $n = if ($val -is [byte[]]) {
            if ($val.Length -eq 1) { [int]$val[0] }
            elseif ($val.Length -eq 4) { [BitConverter]::ToUInt32($val, 0) }
            else { throw "Unexpected SetupProgress binary length: $($val.Length)." }
        } else { [int]$val }
        if ($n -ge 0 -and $n -le 100) { return $n }
        Write-Log "Ignoring out-of-range SetupProgress value: $n." "WARN"
        return $null
    } catch {
        Write-Log "Could not read SetupProgress; retaining the previous percentage: $_" "WARN"
        return $null
    }
}

function Get-SetupProgressPercent {
    <#
    Returns only Microsoft's documented MoSetup SetupProgress value. The
    ChildCompletion value and arbitrary percentage text in setupact.log are
    scoped implementation details and are not safe end-to-end counters.
    Even MoSetup is mapped only within the independently verified phase.
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

function Get-SetupPhaseEvidence {
    param([string[]]$Paths, [DateTimeOffset]$StartedAtUtc)
    $phaseNames = @{ 3 = "Downlevel Phase"; 4 = "Safe OS Phase"; 5 = "First Boot Phase"; 6 = "Second Boot (OOBE) Phase" }
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        # Match execution starts only, never queued/planned operations or arbitrary phase text.
        $matchesInFile = Select-String -LiteralPath $path -Pattern '\bSP\s+(Executing phase \[|OPERATIONTRACK ExecuteOperations: Start execution phase )' -ErrorAction Stop
        foreach ($matchInFile in $matchesInFile) {
            if ($matchInFile.Line -notmatch '^(?<stamp>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d),.*?\bSP\s+(?:Executing phase \[(?<name>[^\]]+)\]|OPERATIONTRACK ExecuteOperations: Start execution phase (?<name>[^\r\n]+))\s*$') { continue }
            $stamp = $Matches['stamp']
            $phase = switch -Regex ($Matches['name'].Trim()) {
                '^Downlevel$' { 3 }
                '^Safe OS$' { 4 }
                '^(Pre|Post) (SysPrep|First Boot)$' { 5 }
                '^(Pre|Post) OOBE( Boot)?$' { 6 }
                default { 0 }
            }
            if (-not $phase) { continue }
            $localTime = [datetime]::ParseExact($stamp, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
            $eventUtc = ([DateTimeOffset]$localTime).ToUniversalTime()
            if ($eventUtc -lt $StartedAtUtc.AddSeconds(-1) -or $eventUtc -gt [DateTimeOffset]::UtcNow.AddMinutes(1)) { continue }
            [pscustomobject]@{
                Phase = $phase
                PhaseName = $phaseNames[$phase]
                StartedAtUtc = $eventUtc.ToString("o")
                Source = "WindowsSetup.ExecutionLog"
                Path = $path
                Evidence = $matchInFile.Line.Trim()
            }
        }
    }
}

function Update-SetupPhaseHistory {
    $launchTime = Get-UpgradeRegistryValue -Name "SetupLaunchTimeUtc"
    if (-not $launchTime) { return @() }
    $paths = @(
        "$env:SystemDrive\`$WINDOWS.~BT\Sources\Panther\setupact.log",
        (Join-Path $env:WINDIR "Panther\setupact.log")
    )
    $historyJson = Get-UpgradeRegistryValue -Name "SetupPhaseHistory" -Default "[]"
    $history = @(ConvertFrom-UpgradePhaseHistory -History $historyJson)
    $signature = (@(foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            $file = Get-Item -LiteralPath $path -ErrorAction Stop
            "$path|$($file.Length)|$($file.LastWriteTimeUtc.Ticks)"
        }
    }) -join ";")
    $normalizedHistoryJson = ConvertTo-Json -InputObject $history -Depth 4 -Compress
    if ($signature -eq (Get-UpgradeRegistryValue -Name "SetupLogScanSignature") -and $historyJson -eq $normalizedHistoryJson) {
        return $history
    }
    $events = @(Get-SetupPhaseEvidence -Paths $paths -StartedAtUtc ([DateTimeOffset]::Parse($launchTime)))
    $combined = @(@($history) + @($events) | Group-Object Phase | ForEach-Object {
        $_.Group | Sort-Object StartedAtUtc | Select-Object -First 1
    } | Sort-Object Phase)
    foreach ($entry in $combined) {
        if (-not ($history | Where-Object { $_.Phase -eq $entry.Phase })) {
            Write-Log "Setup log confirms $($entry.PhaseName) started at $($entry.StartedAtUtc) (recovered evidence, not a claim of live visibility)."
        }
    }
    Set-UpgradeRegistryValue -Name "SetupPhaseHistory" -Value (ConvertTo-Json -InputObject $combined -Depth 4 -Compress)
    Set-UpgradeRegistryValue -Name "SetupLogScanSignature" -Value $signature
    return $combined
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
        -PercentComplete 0 -PercentSource "Measured" -ProgressSource "StageBoundary.Validation" -ProgressFreshness "Milestone" `
        -Notes "Windows Setup completed; validating build, edition, activation, services, and retained configuration."
    Write-Log "Running post-upgrade validation..."
    $issues = @()

    $osNow = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop
    $buildNow = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop).CurrentBuildNumber
    if (-not $targetBuild -or $buildNow -ne $targetBuild -or $osNow.BuildNumber -ne $targetBuild) {
        Set-Phase -Phase 7 -PhaseName "Post-Upgrade Validation" -Status "Failed" `
            -ProgressSource "PostUpgradeValidation.Build" -ProgressFreshness "Terminal" `
            -Notes "Cannot confirm upgrade: expected build '$targetBuild', registry build '$buildNow', live OS build '$($osNow.BuildNumber)'. Review Setup logs; a PostOOBE marker alone does not prove success."
        return
    }
    Set-UpgradeRegistryValue -Name "VerifiedTargetBuild" -Value $buildNow

    try {
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
        $lic = Get-CimInstance SoftwareLicensingProduct -OperationTimeoutSec 10 -ErrorAction Stop |
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
# Main (one writer invocation at a time, including direct Setup hook calls)
# =============================================================================
function Invoke-UpgradeStatusUpdate {
    $currentBuild = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop).CurrentBuildNumber
    $sourceBuild = Get-UpgradeRegistryValue -Name "SourceBuild"
    $targetBuild = Get-UpgradeRegistryValue -Name "TargetBuild"
    $lastPhase = [int](Get-UpgradeRegistryValue -Name "Phase" -Default 0)
    $lastStatus = Get-UpgradeRegistryValue -Name "Status" -Default ""
    $lastPhaseName = Get-UpgradeRegistryValue -Name "PhaseName" -Default "Downlevel Phase"
    if ($lastPhase -lt 3) { return }

    if ($lastStatus -in @("Completed", "CompletedWithWarnings", "Failed") -and
        (-not (Test-Path $script:MarkerRB) -or ($lastStatus -eq "Failed" -and $lastPhase -eq 99))) {
        foreach ($taskName in @("OSUpgradePhaseMonitor", "OSUpgradeRebootWatcher", "OSUpgradeSetupLaunch")) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        return
    }
    if (Test-Path $script:MarkerRB) {
        try {
            $lastExecuted = Update-SetupPhaseHistory | Sort-Object Phase | Select-Object -Last 1
            if ($lastExecuted -and [int]$lastExecuted.Phase -gt $lastPhase -and $lastPhase -lt 7) {
                $lastPhaseName = $lastExecuted.PhaseName
            }
        } catch { Write-Log "Could not recover the last executed phase before rollback: $_" "WARN" }
        try {
            $setupDiagPath = Join-Path $env:WINDIR "Logs\SetupDiag\SetupDiagResults.xml"
            if (Test-Path $setupDiagPath) {
                Copy-Item -LiteralPath $setupDiagPath -Destination (Join-Path $script:LogDir "SetupDiagResults.xml") -Force -ErrorAction Stop
            }
        } catch { Write-Log "Could not preserve SetupDiag results: $_" "WARN" }
        Set-Phase -Phase 99 -PhaseName "Rolled Back" -Status "Failed" `
            -ProgressSource "WindowsSetup.PostRollback" -ProgressFreshness "Terminal" `
            -Notes "Windows Setup invoked /PostRollback. Upgrade failed after '$lastPhaseName'. Review Panther logs and Windows\Logs\SetupDiag\SetupDiagResults.xml."
        foreach ($taskName in @("OSUpgradePhaseMonitor", "OSUpgradeRebootWatcher", "OSUpgradeSetupLaunch")) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        return
    }
    if ($RebootInitiated) {
        if (Get-UpgradeRegistryValue -Name "SetupLaunchTimeUtc") {
            Set-UpgradeRegistryValue -Name "RestartRequestedAtUtc" -Value ([DateTimeOffset]::UtcNow.ToString("o"))
            Set-UpgradeRegistryValue -Name "ExpectedDisconnect" -Value 1 -Type DWord
            Set-Phase -Phase $lastPhase -PhaseName $lastPhaseName -ProgressFreshness "CarriedForward" `
                -Notes "Event 1074 records a restart request. Safe OS is not confirmed; waiting for current-run Setup execution evidence."
        }
        return
    }

    $bootChanged = Update-UpgradeBootEvidence
    if ($bootChanged) {
        Set-UpgradeRegistryValue -Name "ExpectedDisconnect" -Value 0 -Type DWord
        $bootTime = [DateTimeOffset]::Parse((Get-UpgradeRegistryValue -Name "LastObservedBootTimeUtc"))
        $unexpectedRestart = Get-WinEvent -FilterHashtable @{
            LogName = "System"; ProviderName = "Microsoft-Windows-Kernel-Power"; Id = 41
            StartTime = $bootTime.LocalDateTime.AddMinutes(-2)
        } -MaxEvents 1 -ErrorAction SilentlyContinue
        if ($unexpectedRestart) {
            Set-UpgradeRegistryValue -Name "UnexpectedRestartAtUtc" -Value $bootTime.ToString("o")
            Write-Log "Unexpected restart detected during '$lastPhaseName'; checking Setup liveness and the live OS build." "WARN"
        }
    }
    Write-Log "Poll: build=$currentBuild source=$sourceBuild target=$targetBuild phase=$lastPhase status=$lastStatus bootChanged=$bootChanged"
    if (-not $sourceBuild -or -not $targetBuild) { throw "SourceBuild/TargetBuild metadata is missing; cannot safely classify or complete this upgrade." }

    $phaseHistory = @()
    try {
        if ($bootChanged -or $currentBuild -ne $sourceBuild -or $lastPhase -ge 5) {
            $phaseHistory = @(Update-SetupPhaseHistory)
        } else {
            $phaseHistory = @(ConvertFrom-UpgradePhaseHistory -History (Get-UpgradeRegistryValue -Name "SetupPhaseHistory"))
        }
    }
    catch { Write-Log "Could not recover Setup phase history: $_" "WARN" }
    $setupState = Get-ItemProperty "HKLM:\SYSTEM\Setup" -ErrorAction Stop
    $setupProc = @(Get-Process -Name "setuphost", "setupprep", "setup" -ErrorAction SilentlyContinue)
    $oobeMarkerExists = Test-Path $script:MarkerOOBE
    $setupFinished = ($null -ne $setupState.SystemSetupInProgress -and $setupState.SystemSetupInProgress -eq 0 -and
        $null -ne $setupState.OOBEInProgress -and $setupState.OOBEInProgress -eq 0 -and $setupProc.Count -eq 0)

    if ($oobeMarkerExists -or ($currentBuild -eq $targetBuild -and $currentBuild -ne $sourceBuild -and $setupFinished)) {
        $completionSource = if ($oobeMarkerExists) { "WindowsSetup.PostOOBE" } else { "LiveOS.SetupFlagsClear" }
        Set-UpgradeRegistryValue -Name "CompletionEvidence" -Value $completionSource
        if ($lastPhase -lt 7) {
            Set-Phase -Phase 6 -PhaseName "Second Boot (OOBE) Phase" -PercentComplete 100 `
                -ProgressSource $completionSource -ProgressFreshness "Milestone" `
                -Notes "Setup completion evidence=$completionSource; validating the actual target build next."
        }
        # Always resume Phase 7, including the missing-hook path after interrupted validation.
        Invoke-PostUpgradeValidation
        return
    }

    if ($currentBuild -eq $targetBuild -and $currentBuild -ne $sourceBuild) {
        Remove-ItemProperty -Path $script:RegRoot -Name "SetupProcessMissingSinceUtc" -ErrorAction SilentlyContinue
        $phase = if ($setupState.OOBEInProgress -eq 1 -or ($phaseHistory | Where-Object { $_.Phase -eq 6 })) { 6 } else { 5 }
        $phase = [math]::Max($phase, $lastPhase)
        $phaseName = switch ($phase) { 5 { "First Boot Phase" } 6 { "Second Boot (OOBE) Phase" } default { "Post-Upgrade Validation" } }
        $note = "Target build is running; SystemSetupInProgress=$($setupState.SystemSetupInProgress), OOBEInProgress=$($setupState.OOBEInProgress). Waiting for Setup completion before validation."
    } elseif ($currentBuild -eq $sourceBuild) {
        $phase = $lastPhase
        $phaseName = $lastPhaseName
        if (-not $setupProc.Count) {
            $nowUtc = [DateTimeOffset]::UtcNow
            $missingSinceUtc = Get-UpgradeRegistryValue -Name "SetupProcessMissingSinceUtc"
            if (-not $missingSinceUtc) {
                $missingSinceUtc = $nowUtc.ToString("o")
                Set-UpgradeRegistryValue -Name "SetupProcessMissingSinceUtc" -Value $missingSinceUtc
                Write-Log "No Setup process on source build after '$lastPhaseName'. Checking for recovery for up to 10 minutes; an earlier restart request does not suppress this check." "WARN"
            }
            $missingMinutes = ($nowUtc - [DateTimeOffset]::Parse($missingSinceUtc)).TotalMinutes
            if ($missingMinutes -ge 10) {
                try { $phaseHistory = @(Update-SetupPhaseHistory) }
                catch { Write-Log "Could not recover Setup history while investigating a stopped process: $_" "WARN" }
                $lastExecuted = $phaseHistory | Sort-Object Phase | Select-Object -Last 1
                if ($lastExecuted -and [int]$lastExecuted.Phase -gt $phase -and $phase -lt 7) {
                    $phase = [int]$lastExecuted.Phase
                    $phaseName = $lastExecuted.PhaseName
                }
                $taskInfo = Get-ScheduledTaskInfo -TaskName "OSUpgradeSetupLaunch" -ErrorAction SilentlyContinue
                $taskResult = if ($taskInfo) { $taskInfo.LastTaskResult } else { "unavailable" }
                Set-UpgradeRegistryValue -Name "SetupFailureDetectedAtUtc" -Value $nowUtc.ToString("o")
                Set-Phase -Phase $phase -PhaseName $phaseName -Status "Failed" `
                    -ProgressSource "SetupProcessLiveness" -ProgressFreshness "Terminal" `
                    -Notes "Setup stopped/interrupted after last confirmed phase '$phaseName': still on source build $sourceBuild with no Setup process for $([math]::Round($missingMinutes, 1)) minutes. Reboots=$(Get-UpgradeRegistryValue -Name 'RebootCount' -Default 0); unexpected restart=$(Get-UpgradeRegistryValue -Name 'UnexpectedRestartAtUtc'); task result=$taskResult. Kindly check Panther setupact.log/setuperr.log and SetupDiag for the exact failing operation before retrying."
                return
            }
            Set-Phase -Phase $phase -PhaseName $phaseName -ProgressSource "SetupProcessLiveness" -ProgressFreshness "CarriedForward" `
                -Notes "ATTENTION: no Setup process on source build $sourceBuild for $([math]::Round($missingMinutes, 1)) min after '$lastPhaseName'. Checking for recovery; failure will be reported after 10 minutes. Review the target if it was reset."
            return
        }
        Remove-ItemProperty -Path $script:RegRoot -Name "SetupProcessMissingSinceUtc" -ErrorAction SilentlyContinue
        $note = "Windows Setup is running on source build $sourceBuild. The MoSetup counter is scoped to Downlevel, not overall upgrade completion."
    } else {
        Set-Phase -Phase $lastPhase -PhaseName $lastPhaseName -Status "Failed" `
            -ProgressSource "LiveOS.Build" -ProgressFreshness "Terminal" `
            -Notes "Unexpected live build $currentBuild (source=$sourceBuild, target=$targetBuild). Cannot confirm upgrade state; investigate manually."
        return
    }

    $logPath = if ($currentBuild -eq $sourceBuild) { "$env:SystemDrive\`$WINDOWS.~BT\Sources\Panther\setupact.log" } else { Join-Path $env:WINDIR "Panther\setupact.log" }
    $logTail = Get-SetupLogTail -Path $logPath
    if ($logTail) { Set-UpgradeRegistryValue -Name "SetupLogTail" -Value $logTail }
    $result = Get-SetupProgressPercent
    $phaseArgs = @{ Phase = $phase; PhaseName = $phaseName; Notes = $note; ProgressSource = "MoSetup.SetupProgress.PhaseScoped"; ProgressFreshness = "CarriedForward" }
    if ($null -ne $result -and $phase -lt 7) {
        Set-UpgradeRegistryValue -Name "SetupTelemetryPercent" -Value $result.Percent -Type DWord
        Set-UpgradeRegistryValue -Name "SetupTelemetryPhase" -Value $phase -Type DWord
        Set-UpgradeRegistryValue -Name "SetupTelemetrySource" -Value "MoSetup.SetupProgress"
        $phaseArgs["PercentComplete"] = $result.Percent
        $phaseArgs["ProgressFreshness"] = "Live"
    } elseif ($phase -ne $lastPhase) {
        $phaseArgs["ProgressSource"] = "LiveOS.PhaseBoundary"
    }
    Set-Phase @phaseArgs
}

$monitorMutex = New-Object System.Threading.Mutex($false, "Global\OSUpgradeAutomationMonitor")
$monitorLockTaken = $false
try {
    try { $monitorLockTaken = $monitorMutex.WaitOne(1000) }
    catch [System.Threading.AbandonedMutexException] { $monitorLockTaken = $true }
    if (-not $monitorLockTaken) {
        Write-Log "Another monitor/hook invocation is active; the recurring task will retry." "WARN"
        return
    }
    Remove-ItemProperty -Path $script:RegRoot -Name "MonitorLastError" -ErrorAction SilentlyContinue
    Invoke-UpgradeStatusUpdate
} catch {
    Write-Log "Status monitor failed and will retry on its next trigger: $_" "ERROR"
    Set-UpgradeRegistryValue -Name "MonitorLastError" -Value $_.Exception.Message
    Write-StatusJson
    throw
} finally {
    if ($monitorLockTaken) { $monitorMutex.ReleaseMutex() }
    $monitorMutex.Dispose()
}
