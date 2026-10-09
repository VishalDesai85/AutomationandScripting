<#
.SYNOPSIS
    REMOTE ORCHESTRATOR / MONITORING SCRIPT - runs ON Server A (the management
    machine). Stages the target execution files onto Server B, kicks off the
    in-place upgrade there, then monitors Server B's online/offline state and
    upgrade phase/progress in real time on Server A's console - surviving the
    multiple reboots Server B will go through.

.DESCRIPTION
    Step 1  - Validate local companion files exist and Server B is currently
              reachable (ping is best-effort only; WinRM is the real gate,
              probed over HTTP/5985 first then automatically over HTTPS/5986).
    Step 2  - Open a PSSession to Server B, copy the 6 target-side files into a
              staging folder, and invoke Start-TargetUpgrade.ps1 there. This
              call returns as soon as Server B's pre-checks/backup/mount are
              done and setup.exe has been launched - it does NOT block for the
              whole upgrade (that would exceed any reasonable session/command
              timeout across multiple reboots).
    Step 3  - Enter a monitoring loop that, every -PollIntervalSeconds:
                a. Pings Server B (fast timeout) to know ONLINE / OFFLINE.
                b. Explicitly probes WinRM (Test-WSMan, time-boxed) to know
                   whether "Active Polling" mode is available. WinRM WILL
                   drop when Server B tears down networking to enter Safe
                   OS/WinPE - this is expected, not an error condition: the
                   script logs "WinRM connectivity LOST" and automatically
                   downgrades to "Heartbeat" (ping-only) mode, then logs
                   "WinRM connectivity RESTORED" and transparently resumes
                   Active Polling the moment Test-WSMan succeeds again after
                   First/Second Boot - no manual reconnection is ever needed.
                c. Prefers fresh atomic status JSON over SMB. If unavailable
                   or stale, makes one bounded WinRM status/OS-state read;
                   DCOM remains an independent fallback. Task recovery is
                   requested only for stale status and at most once a minute.
                d. If NONE of ping/WinRM/file/DCOM succeed, reports a
                   connectivity outage with an UNCONFIRMED phase. Safe OS
                   execution is recovered from current-run Setup logs;
                   network availability alone never establishes a phase.
                e. Renders progress and warns when producer status is stale.
    Step 4  - Prints a clear success banner once Server B is back online,
              WinRM has reconnected (Active Polling confirmed - not just a
              ping), Status=Completed(/CompletedWithWarnings), and its live
              OS build matches the expected target build and Setup/OOBE flags
              are clear. Prints a failure
              banner on Failed/RolledBack, or a timeout warning if
              -TimeoutMinutes elapses first. A reported completion that
              cannot be verified within -FinalValidationTimeoutSeconds
              ends with an explicit validation error, never assumed success.

.PARAMETER TargetComputer
    Hostname or IP of Server B.

.PARAMETER Credential
    Optional PSCredential for Server B (required for workgroup targets or
    when Server A's current user isn't a local admin on Server B). When
    supplied, all WinRM probes and PowerShell remoting calls explicitly use
    Negotiate authentication. Without it, existing current-user authentication
    behavior is retained.

.PARAMETER UseSSL
    Skip the HTTP (5985) probe entirely and connect to WinRM over HTTPS
    (5986) only. Without this switch the script AUTO-DETECTS: it tries
    HTTP 5985 first and, if that fails, automatically retries over HTTPS
    5986 before giving up - so a target whose only open WinRM port is 5986
    works with no extra parameters. Use this switch when 5985 is known to
    be blocked and you don't want to wait through its probe timeout, or to
    enforce encrypted transport as a policy.

.PARAMETER SkipCertificateCheck
    Only relevant for HTTPS/5986. By default the HTTPS probe performs FULL
    certificate validation, so a self-signed or name-mismatched WinRM
    listener certificate will (correctly) fail. Pass this switch to also
    attempt HTTPS with certificate CA/CN/revocation checks bypassed - this
    weakens transport security and is never done automatically, so it must
    be an explicit, deliberate choice. Prefer installing a trusted
    certificate whose CN/SAN matches the exact -TargetComputer value.

.PARAMETER SourceFilesPath
    Folder on Server A containing the 6 target-side files. Default: the
    "..\ServerB-Target" folder next to this script.

.PARAMETER RemoteStagingPath
    Temporary staging folder on Server B the files are copied into before
    Start-TargetUpgrade.ps1 relocates what it needs to its permanent
    C:\ProgramData\OSUpgradeAutomation location. Default: C:\Temp\OSUpgradeStaging

.PARAMETER IsoFolder, MinFreeSpaceGB, BackupRoot, StatusJsonPath, RetentionDays,
.PARAMETER DisableAutoCleanup, SkipPatchCheckLab, SkipSystemStateBackup, SkipOrphanedProfileCheck,
.PARAMETER MinVMwareToolsVersion, UseControlledReboot, MaxPatchAgeDays
    Passed straight through to Start-TargetUpgrade.ps1 on Server B - see that
    script's own help for details. -SkipSystemStateBackup omits backup task
    8 of 8 (the slow wbadmin system state backup); every other backup
    artifact is still produced.

.PARAMETER SkipUserProfileCountCheck
    Deprecated compatibility switch passed through to the target. Profile
    counting is always warning-only; no bypass is needed. Inventory and the
    duration warning still run when this switch is supplied.

.PARAMETER SkipPendingFileRenameCheck
    Pass through to the target: bypass only PendingFileRenameOperations.
    Queued operations are still reported; CBS and Windows Update reboot
    requirements remain blocking. No registry values are deleted.

.PARAMETER PollIntervalSeconds
    Seconds between monitoring checks while WinRM/Active Polling is up.
    Also the minimum interval between precheck/backup status reads.
    Default: 15. Probe duration is additional to the monitoring sleep.

.PARAMETER FastPollIntervalSeconds
    Seconds between monitoring checks ONLY while Mode is Heartbeat or
    Offline (WinRM down) - a shorter interval here increases the odds of
    catching a brief window where the machine responds again (e.g. a
    short-lived First Boot state before OOBE fires), instead of only ever
    polling every -PollIntervalSeconds and potentially missing a phase that
    only existed for a few seconds. Default: 5.

.PARAMETER TimeoutMinutes
    Overall monitoring timeout. Default: 180 (3 hours - in-place upgrades with
    multiple reboots commonly take 60-120 minutes; tune per environment).
    The precheck/backup kickoff wait is separately capped at this duration.

.PARAMETER StatusStaleWarningMinutes
    Warn when target status publication stops advancing or cannot be read.
    Default: 5. A connectivity gap is not proof of failure or Safe OS. The
    target separately fails a stopped Setup process on the source OS after
    a 10-minute recovery grace period.

.PARAMETER FinalValidationTimeoutSeconds
    Maximum final-verification wait after the target reports completion.
    Default: 60 seconds, with an immediate check and subsequent five-second
    retry delays. Shows one "Validating update..." message; retry details go
    to the log. Unverified completion ends with an error and exit code 3,
    never a successful fallback. The overall monitoring deadline still applies.

.PARAMETER LocalStatusMirrorPath
    Optional path on Server A for an atomic mirror of Server B's latest real
    status. During reboots/WinPE, producer fields are retained unchanged and
    an Observer object reports connectivity and cache age. Default: beside the
    orchestrator logs under ProgramData.

.EXAMPLE
    .\Start-RemoteUpgradeOrchestrator.ps1 -TargetComputer "ServerB" -IsoFolder "D:\ISO"

.EXAMPLE
    Workgroup target, lab run bypassing only the patch-currency hard stop:
    $cred = Get-Credential
    .\Start-RemoteUpgradeOrchestrator.ps1 -TargetComputer "ServerB" -Credential $cred -SkipPatchCheckLab -RetentionDays 1

.EXAMPLE
    Target where only the HTTPS WinRM listener (5986) is open, using an
    internally-issued certificate that Server A already trusts:
    .\Start-RemoteUpgradeOrchestrator.ps1 -TargetComputer "ServerB.contoso.com" -UseSSL

.EXAMPLE
    Same, but the 5986 listener uses a self-signed certificate (accept it
    explicitly - the channel stays encrypted, but identity is unverified):
    .\Start-RemoteUpgradeOrchestrator.ps1 -TargetComputer "ServerB" -UseSSL -SkipCertificateCheck
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TargetComputer,

    [System.Management.Automation.PSCredential]$Credential,

    # WinRM transport control - see .PARAMETER help above. Default (neither
    # switch) = try HTTP 5985, then automatically fall back to HTTPS 5986.
    [switch]$UseSSL,
    [switch]$SkipCertificateCheck,

    [string]$SourceFilesPath   = "",
    [string]$RemoteStagingPath = "C:\Temp\OSUpgradeStaging",

    # --- Pass-through parameters for Start-TargetUpgrade.ps1 -----------------
    [string]$IsoFolder             = "D:\ISO",
    [int]   $MinFreeSpaceGB        = 32,
    [string]$BackupRoot            = "D:\UpgradeBackup",
    [string]$StatusJsonPath        = "D:\upgrade_status.json",
    [int]   $RetentionDays         = 14,
    [switch]$DisableAutoCleanup,
    [switch]$SkipPatchCheckLab,
    [switch]$SkipSystemStateBackup,
    [switch]$SkipOrphanedProfileCheck,
    [switch]$SkipUserProfileCountCheck,
    [switch]$SkipPendingFileRenameCheck,
    [string]$MinVMwareToolsVersion = "12.0.0",
    [switch]$UseControlledReboot,
    [int]   $MaxPatchAgeDays       = 60,

    # --- Monitoring parameters -------------------------------------------------
    [ValidateRange(1,3600)][int]$PollIntervalSeconds = 15,
    # Used ONLY while Mode is Heartbeat or Offline (WinRM down) - a shorter
    # interval here increases the odds of a poll actually landing during a
    # brief window where the machine responds again (e.g. a short-lived
    # First Boot state before OOBE fires), instead of only ever polling
    # every 15s and potentially missing a phase that only existed for a few
    # seconds. Reverts to the normal $PollIntervalSeconds the instant Mode
    # is back to ActivePolling - no reason to poll aggressively once WinRM
    # is confirmed up and richer data is flowing normally.
    [ValidateRange(1,3600)][int]$FastPollIntervalSeconds = 5,
    [ValidateRange(1,10080)][int]$TimeoutMinutes = 180,
    [ValidateRange(1,10080)][int]$PhaseStallWarningMinutes = 45,
    [ValidateRange(1,10080)][int]$StatusStaleWarningMinutes = 5,
    [ValidateRange(1,600)][int]$FinalValidationTimeoutSeconds = 60,
    [string]$LocalStatusMirrorPath = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($SourceFilesPath)) {
    $SourceFilesPath = Join-Path (Split-Path -Parent $PSScriptRoot) "ServerB-Target"
}

# =============================================================================
# SECTION 1 - LOCAL LOGGING (on Server A)
# =============================================================================
$script:LocalLogDir = Join-Path $env:ProgramData "OSUpgradeAutomation\OrchestratorLogs"
if (-not (Test-Path $script:LocalLogDir)) { New-Item -ItemType Directory -Path $script:LocalLogDir -Force | Out-Null }
$script:LocalLogFile = Join-Path $script:LocalLogDir "Orchestrator_$($TargetComputer)_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$safeTargetName = $TargetComputer -replace '[<>:"/\\|?*]', '_'
if (-not $LocalStatusMirrorPath) {
    $LocalStatusMirrorPath = Join-Path $script:LocalLogDir "UpgradeStatus_$($safeTargetName)_Latest.json"
}
$script:LocalStatusMirrorPath = $LocalStatusMirrorPath

function Write-Log {
    param([string]$Message, [ValidateSet("INFO","WARN","ERROR","SUCCESS")][string]$Level = "INFO", [switch]$LogOnly)
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    if (-not $LogOnly) {
        switch ($Level) {
            "ERROR"   { Write-Host $line -ForegroundColor Red }
            "WARN"    { Write-Host $line -ForegroundColor Yellow }
            "SUCCESS" { Write-Host $line -ForegroundColor Green }
            default   { Write-Host $line }
        }
    }
    Add-Content -Path $script:LocalLogFile -Value $line -Encoding UTF8
}

$script:LastProducerStatus = $null
$script:LastProducerReadAtUtc = $null
$script:ProducerCacheRecovered = $false
$script:MirrorWriteWarningLogged = $false

function ConvertTo-ProducerStatusRecord {
    param([object]$Status)

    $record = [ordered]@{}
    foreach ($property in $Status.PSObject.Properties) {
        if ($property.Name -notin @("PingOk", "WinRmOk", "Mode", "Source", "Observer", "LiveState", "HealthWarning")) {
            $record[$property.Name] = $property.Value
        }
    }
    if (-not $record.Contains("IsTerminal")) {
        $record["IsTerminal"] = ($record["Status"] -in @("Completed", "CompletedWithWarnings", "Failed"))
    }
    return $record
}

function Import-LocalStatusMirrorCache {
    if (-not (Test-Path $script:LocalStatusMirrorPath)) { return }

    try {
        $existingMirror = Get-Content -Path $script:LocalStatusMirrorPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $existingTarget = if ($existingMirror.Observer -and $existingMirror.Observer.TargetComputer) {
            $existingMirror.Observer.TargetComputer
        } else {
            $existingMirror.ComputerName
        }
        if ($existingTarget -and $existingTarget -ne $TargetComputer) {
            throw "Mirror belongs to '$existingTarget', not '$TargetComputer'."
        }
        if (-not $existingMirror.RunId -or $existingMirror.Status -eq "AwaitingProducerStatus") { return }

        $script:LastProducerStatus = ConvertTo-ProducerStatusRecord -Status $existingMirror
        if ($existingMirror.Observer -and $existingMirror.Observer.LastProducerReadAtUtc) {
            $script:LastProducerReadAtUtc = [DateTimeOffset]::Parse($existingMirror.Observer.LastProducerReadAtUtc)
        } elseif ($existingMirror.StatusUpdatedAtUtc) {
            $script:LastProducerReadAtUtc = [DateTimeOffset]::Parse($existingMirror.StatusUpdatedAtUtc)
        } else {
            $script:LastProducerReadAtUtc = [DateTimeOffset](Get-Item $script:LocalStatusMirrorPath).LastWriteTimeUtc
        }
        $script:ProducerCacheRecovered = $true
        Write-Log "Recovered cached producer status RunId=$($existingMirror.RunId), Sequence=$($existingMirror.Sequence) from the existing Server A mirror." "WARN"
    } catch {
        Write-Log "Ignoring unreadable or mismatched existing status mirror '$script:LocalStatusMirrorPath': $_" "WARN"
        $script:LastProducerStatus = $null
        $script:LastProducerReadAtUtc = $null
        $script:ProducerCacheRecovered = $false
    }
}

function Write-LocalStatusMirror {
    param(
        [object]$ProducerStatus,
        [object]$ObservationStatus,
        [string]$ObservationError = ""
    )

    try {
        $nowUtc = [DateTimeOffset]::UtcNow
        if ($null -ne $ProducerStatus) {
            $script:LastProducerStatus = ConvertTo-ProducerStatusRecord -Status $ProducerStatus
            $script:LastProducerReadAtUtc = $nowUtc
            $script:ProducerCacheRecovered = $false
        }

        if ($null -ne $script:LastProducerStatus) {
            $mirror = [ordered]@{}
            foreach ($name in $script:LastProducerStatus.Keys) {
                $mirror[$name] = $script:LastProducerStatus[$name]
            }
            $cacheAgeSeconds = [int][math]::Max(0, [math]::Floor(($nowUtc - $script:LastProducerReadAtUtc).TotalSeconds))
            $cacheState = if ($null -ne $ProducerStatus) {
                "Fresh"
            } elseif ($script:ProducerCacheRecovered) {
                "RecoveredFromDisk"
            } else {
                "CarriedForward"
            }
        } else {
            $mirror = [ordered]@{
                SchemaVersion          = 2
                RunId                  = $null
                Sequence               = $null
                ComputerName           = $TargetComputer
                Status                 = "AwaitingProducerStatus"
                IsTerminal             = $false
                Phase                  = $null
                PhaseName              = "Waiting for the first target-produced status snapshot"
                StageNumber            = $null
                Stage                  = $null
                StagePercentComplete   = $null
                OverallPercentComplete = $null
                PercentComplete        = $null
                PercentSource          = $null
                ProgressSource         = $null
                ProgressFreshness      = $null
                ProgressUpdatedAtUtc   = $null
                StatusUpdatedAtUtc     = $null
                LastUpdated            = $null
                Notes                  = "Server A has not received a target-produced status snapshot yet."
            }
            $cacheAgeSeconds = $null
            $cacheState = "NoProducerSnapshot"
        }

        $producerAgeSeconds = $null
        $producerStamp = [DateTimeOffset]::MinValue
        if ($mirror["StatusUpdatedAtUtc"] -and [DateTimeOffset]::TryParse($mirror["StatusUpdatedAtUtc"], [ref]$producerStamp)) {
            $producerAgeSeconds = [int][math]::Max(0, [math]::Floor(($nowUtc - $producerStamp).TotalSeconds))
        }
        $mirror["Observer"] = [ordered]@{
            ComputerName          = $env:COMPUTERNAME
            TargetComputer        = $TargetComputer
            ObservedAtUtc         = $nowUtc.ToString("o")
            LastProducerReadAtUtc = $(if ($script:LastProducerReadAtUtc) { $script:LastProducerReadAtUtc.ToString("o") } else { $null })
            ProducerReachable     = ($null -ne $ProducerStatus)
            CacheState            = $cacheState
            CacheAgeSeconds       = $cacheAgeSeconds
            ProducerStatusAgeSeconds = $producerAgeSeconds
            ConnectivityMode      = $(if ($ObservationStatus) { $ObservationStatus.Mode } else { "Initializing" })
            ConnectivitySource    = $(if ($ObservationStatus) { $ObservationStatus.Source } else { "ServerA" })
            PingOk                = $(if ($ObservationStatus) { $ObservationStatus.PingOk } else { $null })
            WinRmOk               = $(if ($ObservationStatus) { $ObservationStatus.WinRmOk } else { $null })
            LiveState             = $(if ($ObservationStatus) { $ObservationStatus.LiveState } else { $null })
            HealthWarning         = $(if ($ObservationStatus) { $ObservationStatus.HealthWarning } else { $null })
            ObservationError      = $(if ($ObservationError) { $ObservationError } else { $null })
        }

        $mirrorDirectory = Split-Path -Parent $script:LocalStatusMirrorPath
        if ($mirrorDirectory -and -not (Test-Path $mirrorDirectory)) {
            New-Item -ItemType Directory -Path $mirrorDirectory -Force | Out-Null
        }
        Write-UpgradeJsonFile -Path $script:LocalStatusMirrorPath -Json ($mirror | ConvertTo-Json -Depth 8)
        $script:MirrorWriteWarningLogged = $false
    } catch {
        if (-not $script:MirrorWriteWarningLogged) {
            Write-Log "Non-blocking: could not update local status mirror '$script:LocalStatusMirrorPath': $_" "WARN"
            $script:MirrorWriteWarningLogged = $true
        }
    }
}

Write-Log "===================================================================="
Write-Log "Start-RemoteUpgradeOrchestrator.ps1 - target: $TargetComputer"
Write-Log "===================================================================="

# =============================================================================
# SECTION 1b - WINRM TRANSPORT RESOLUTION (HTTP 5985 -> HTTPS 5986 FALLBACK)
# =============================================================================
# WinRM performs NO protocol/port negotiation of its own: a cmdlet without
# -UseSSL talks HTTP/5985 and never retries over HTTPS/5986 by itself. Since
# an environment may legitimately expose ONLY the HTTPS listener, every WinRM
# call in this script goes through a single resolved transport determined
# once here, up front, instead of hardcoding the HTTP default.
#
# Must be defined BEFORE Section 2 uses it - PowerShell does not hoist
# function definitions.
$script:WinRMTransport = $null

# Shared by both the up-front resolver and the monitoring loop's recurring
# liveness probe, so the two can never drift apart.
$script:WinRMProbeScript = {
    param(
        [string]$cn,
        [System.Management.Automation.PSCredential]$cred,
        [string]$transport
    )
    try {
        switch ($transport) {
            "Http" {
                $p = @{ ComputerName = $cn; Port = 5985; ErrorAction = "Stop" }
                if ($cred) {
                    $p["Credential"] = $cred
                    $p["Authentication"] = "Negotiate"
                }
                Test-WSMan @p | Out-Null
            }
            "Https" {
                $p = @{ ComputerName = $cn; UseSSL = $true; Port = 5986; ErrorAction = "Stop" }
                if ($cred) {
                    $p["Credential"] = $cred
                    $p["Authentication"] = "Negotiate"
                }
                Test-WSMan @p | Out-Null
            }
            "HttpsSkipCert" {
                # Test-WSMan has no -SessionOption parameter at all, so it can
                # never bypass certificate validation - opening (and instantly
                # disposing) a real session is the only way to probe 5986 when
                # the listener uses a self-signed/name-mismatched certificate.
                $p = @{
                    ComputerName  = $cn
                    UseSSL        = $true
                    Port          = 5986
                    SessionOption = (New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck)
                    ErrorAction   = "Stop"
                }
                if ($cred) {
                    $p["Credential"] = $cred
                    $p["Authentication"] = "Negotiate"
                }
                $s = New-PSSession @p
                Remove-PSSession -Session $s -ErrorAction SilentlyContinue
            }
        }
        $true
    } catch { $false }
}

function Test-WinRMTransport {
    <#
    Probes ONE specific transport with a hard timeout. Wrapped in a background
    job because neither Test-WSMan nor New-PSSession has a native per-call
    timeout - both can block for the full network/RPC timeout against a
    firewalled port or a rebooting machine, which is exactly the condition
    this needs to detect quickly.
    #>
    param(
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Cred,
        [ValidateSet("Http","Https","HttpsSkipCert")][string]$Transport,
        [int]$TimeoutSec = 15
    )
    $job = Start-Job -ScriptBlock $script:WinRMProbeScript -ArgumentList $ComputerName, $Cred, $Transport
    try {
        if (Wait-Job -Job $job -Timeout $TimeoutSec) {
            return [bool](Receive-Job -Job $job -ErrorAction SilentlyContinue)
        }
        return $false
    } finally {
        Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Get-WinRMTransportLabel {
    param([string]$Transport)
    switch ($Transport) {
        "Http"          { "HTTP/5985" }
        "Https"         { "HTTPS/5986 (certificate validated)" }
        "HttpsSkipCert" { "HTTPS/5986 (certificate checks BYPASSED)" }
        default         { "unresolved" }
    }
}

function Resolve-WinRMTransport {
    <#
    Works out which WinRM transport actually answers, in ascending order of
    both cost and security compromise, and returns its name (or $null).
    HttpsSkipCert is ONLY ever attempted when -SkipCertificateCheck was
    explicitly passed - silently downgrading to unvalidated TLS on a cert
    failure would defeat the point of using HTTPS at all.
    #>
    param([string]$ComputerName, [System.Management.Automation.PSCredential]$Cred)

    $order = @()
    if (-not $UseSSL) { $order += "Http" }
    $order += "Https"
    if ($SkipCertificateCheck) { $order += "HttpsSkipCert" }

    foreach ($t in $order) {
        Write-Log "Probing WinRM over $(Get-WinRMTransportLabel $t) on $ComputerName..."
        if (Test-WinRMTransport -ComputerName $ComputerName -Cred $Cred -Transport $t) {
            return $t
        }
        Write-Log "WinRM did not answer over $(Get-WinRMTransportLabel $t) on $ComputerName." "WARN"
    }
    return $null
}

function Get-WinRMSessionParams {
    <#
    Single source of truth for the splat used by New-PSSession/Invoke-Command,
    so the resolved transport is applied consistently everywhere.
    #>
    $p = @{ ComputerName = $TargetComputer }
    if ($Credential) {
        $p["Credential"] = $Credential
        $p["Authentication"] = "Negotiate"
    }
    switch ($script:WinRMTransport) {
        "Https" {
            $p["UseSSL"] = $true
            $p["Port"]   = 5986
        }
        "HttpsSkipCert" {
            $p["UseSSL"]        = $true
            $p["Port"]          = 5986
            $p["SessionOption"] = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        }
    }
    return $p
}

# =============================================================================
# SECTION 2 - PRE-FLIGHT: local files + connectivity to Server B
# =============================================================================
$requiredFiles = @("Start-TargetUpgrade.ps1","OSUpgradeStatus.ps1","Update-UpgradeStatus.ps1","Remove-UpgradeArtifacts.ps1","setupcomplete.cmd","setuprollback.cmd")

# Optional companion tools: not required to start an upgrade, but staged to
# Server B when present locally so the target-side script can use them.
# LGPO.exe (Microsoft's Local Group Policy Object utility, from the Security
# Compliance Toolkit) lets Start-TargetUpgrade.ps1 export local GPOs into a
# real, restorable backup format instead of only a raw robocopy of
# C:\Windows\System32\GroupPolicy - drop LGPO.exe next to this script (or in
# -SourceFilesPath) to enable it; if absent, GPO backup silently falls back
# to the existing robocopy/secedit/gpresult-only approach.
$optionalFiles = @("LGPO.exe")

# Layout auto-detection: the default -SourceFilesPath assumes the two-folder
# layout this solution ships with (ServerA-Orchestrator\ + a sibling
# ServerB-Target\). If that sibling folder doesn't exist - e.g. all 6 files
# were instead dropped flat into one single parent folder - fall back to
# using this script's OWN folder ($PSScriptRoot) as the source, as long as it
# actually contains the 6 required files. This makes both layouts work
# without requiring -SourceFilesPath to be passed manually.
if (-not (Test-Path $SourceFilesPath)) {
    $flatLayoutOk = $true
    foreach ($f in $requiredFiles) { if (-not (Test-Path (Join-Path $PSScriptRoot $f))) { $flatLayoutOk = $false } }
    if ($flatLayoutOk) {
        Write-Log "Sibling folder '$SourceFilesPath' not found - falling back to flat single-folder layout: using $PSScriptRoot as -SourceFilesPath." "WARN"
        $SourceFilesPath = $PSScriptRoot
    }
}

foreach ($f in $requiredFiles) {
    $p = Join-Path $SourceFilesPath $f
    if (-not (Test-Path $p)) { throw "Required target-side file '$f' not found in '$SourceFilesPath'. Verify -SourceFilesPath." }
}
Write-Log "All 6 target-side files found in $SourceFilesPath."
. (Join-Path $SourceFilesPath "OSUpgradeStatus.ps1")
foreach ($helperName in @("Write-UpgradeJsonFile", "ConvertFrom-UpgradePhaseHistory")) {
    if (-not (Get-Command -Name $helperName -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "Companion helper is missing '$helperName'. Deploy the complete matching script set, not only the orchestrator."
    }
}
Import-LocalStatusMirrorCache
Write-LocalStatusMirror
Write-Log "Server A status mirror: $script:LocalStatusMirrorPath"

# NOTE: this is deliberately NON-FATAL, unlike earlier versions of this
# script. Some environments block ICMP entirely via firewall policy, in
# which case ping would NEVER succeed here even though $TargetComputer is
# fully up and WinRM-reachable - a hard-fail on ping alone would have
# prevented the orchestrator from EVER starting in such an environment.
# The Test-WSMan check immediately below is the REAL reachability gate
# that actually matters (it's what staging/kickoff/monitoring depend on);
# ping here is just an early, cheap, best-effort diagnostic hint.
if (-not (Test-Connection -ComputerName $TargetComputer -Count 2 -Quiet -ErrorAction SilentlyContinue)) {
    Write-Log "$TargetComputer is not responding to ping - continuing anyway (ICMP may simply be blocked in this environment). WinRM reachability is checked next and is the real gate." "WARN"
} else {
    Write-Log "$TargetComputer is responding to ping."
}

# WinRM is the real gate. Neither HTTP nor HTTPS is assumed - the resolver
# tries 5985 then automatically falls back to 5986, since a target may only
# have the HTTPS listener open and WinRM never retries across ports on its own.
$script:WinRMTransport = Resolve-WinRMTransport -ComputerName $TargetComputer -Cred $Credential

if (-not $script:WinRMTransport) {
    $hint = @()
    $hint += "Ensure PS Remoting is enabled on the target (Enable-PSRemoting) and that the relevant listener port is open through the firewall: 5985 for HTTP, 5986 for HTTPS (Get-ChildItem WSMan:\localhost\Listener on the target shows which listeners exist)."
    if (-not $UseSSL)               { $hint += "Both HTTP/5985 and HTTPS/5986 were tried automatically and neither answered." }
    if (-not $SkipCertificateCheck) { $hint += "The HTTPS/5986 probe validated the listener certificate - if that listener uses a self-signed or name-mismatched certificate this probe fails by design; re-run with -SkipCertificateCheck to accept it, or install a certificate whose CN/SAN matches '$TargetComputer' exactly." }
    $hint += "For workgroup targets, TrustedHosts must also be configured on Server A."
    throw "WinRM is not reachable on $TargetComputer over any supported transport. $($hint -join ' ')"
}

Write-Log "WinRM reachable on $TargetComputer over $(Get-WinRMTransportLabel $script:WinRMTransport)." "SUCCESS"
if ($script:WinRMTransport -eq "HttpsSkipCert") {
    Write-Log "WinRM certificate validation is BYPASSED for this run (-SkipCertificateCheck). The channel is still encrypted, but the target's identity is NOT verified - install a trusted certificate matching '$TargetComputer' to remove this exposure." "WARN"
}

# Consumed by Invoke-Command/New-PSSession below - built from the resolved transport.
$sessionParams = Get-WinRMSessionParams

# =============================================================================
# SECTION 2b - DETECT AN ALREADY-IN-PROGRESS UPGRADE (RESUME SUPPORT)
# =============================================================================
# This orchestrator registers NO scheduled tasks of its own on Server A - it
# is a plain foreground process only for as long as its monitoring loop is
# running. If it is closed/killed/times out (laptop sleep, network blip,
# Ctrl+C, terminal closed), Server B's own scheduled tasks
# (OSUpgradePhaseMonitor/RebootWatcher/AutoCleanup/SetupLaunch) keep the
# upgrade progressing completely independently - nothing on Server A is
# required for the upgrade itself to continue. But simply re-running this
# script from scratch would otherwise unconditionally re-stage files and
# re-invoke Start-TargetUpgrade.ps1 (which has no re-entrancy guard of its
# own) - re-running prechecks/backup and potentially launching a SECOND
# setup.exe on top of one already mid-upgrade. So: check Server B's own
# last-known Phase/Status first, and if an upgrade is already genuinely
# under way, skip straight to monitoring instead of re-kicking anything off.
$resumeExisting = $false
try {
    $existing = Invoke-Command @sessionParams -ScriptBlock {
        $reg = Get-ItemProperty -Path "HKLM:\SOFTWARE\OSUpgradeAutomation" -ErrorAction SilentlyContinue |
            Select-Object RunId, Phase, PhaseName, Status, PostUpgradeOSCaption, TargetOSCaption, TargetBuild, LastUpdated
        if ($reg) {
            # Status "InProgress" ALONE is not trustworthy - setup.exe can
            # self-cancel (e.g. a OneSettings network-timeout) and leave
            # Status stuck at "InProgress" forever without ever advancing.
            # Require real activity evidence too: a live setup/SetupHost/
            # SetupPrep process, or a setupact.log written within the last
            # 5 minutes - the SAME check Start-TargetUpgrade.ps1's own
            # stale-attempt guard (Section 1b) uses. Real Setup activity
            # writes to that log every few seconds while genuinely working,
            # so even an 18-19 minute-old log is actually strong evidence
            # the attempt already died, not that it's still active (a
            # looser 20-min threshold previously let exactly that slip
            # through as a false positive here).
            $setupIsRunning = [bool](Get-Process -Name "setup","SetupHost","SetupPrep" -ErrorAction SilentlyContinue)
            $btPath = "$env:SystemDrive\`$WINDOWS.~BT"
            $pantherLog = Join-Path $btPath "Sources\Panther\setupact.log"
            $pantherFreshMin = if (Test-Path $pantherLog) { ((Get-Date) - (Get-Item $pantherLog).LastWriteTime).TotalMinutes } else { [double]::PositiveInfinity }
            $reg | Add-Member -NotePropertyName LooksActive -NotePropertyValue ($setupIsRunning -or ($pantherFreshMin -lt 5)) -Force
            $reg | Add-Member -NotePropertyName SetupIsRunning -NotePropertyValue $setupIsRunning -Force
            $reg | Add-Member -NotePropertyName PantherAgeMin -NotePropertyValue $pantherFreshMin -Force
            # LIVE, independent OS caption/build check (2026-07-20) - not
            # just trusting the stored PostUpgradeOSCaption registry value
            # (which, however unlikely, could theoretically be stale if the
            # OS were reverted to a snapshot after that value was written).
            # This is the same Win32_OperatingSystem query the final
            # build-reconfirm step uses later - querying it here too, right
            # at resume-detection time, makes the "nothing to do here, it's
            # already upgraded" message immediately trustworthy and obvious
            # instead of only surfacing deep inside the final summary.
            try {
                $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                $reg | Add-Member -NotePropertyName LiveOSCaption -NotePropertyValue $os.Caption -Force
                $reg | Add-Member -NotePropertyName LiveBuild     -NotePropertyValue $os.BuildNumber -Force
            } catch {
                $reg | Add-Member -NotePropertyName LiveOSCaption -NotePropertyValue $null -Force
                $reg | Add-Member -NotePropertyName LiveBuild     -NotePropertyValue $null -Force
            }
        }
        $reg
    } -ErrorAction Stop
    if ($existing -and $existing.Status -eq "InProgress" -and [int]$existing.Phase -ge 1 -and
        ($existing.LooksActive -or [int]$existing.Phase -ge 3)) {
        $resumeExisting = $true
        Write-Log "Resuming unresolved upgrade on $TargetComputer (Phase=$($existing.Phase) '$($existing.PhaseName)', setup running=$($existing.SetupIsRunning)). Skipping re-stage/re-kickoff; the monitor will reconcile completion or interruption without launching Setup again." "WARN"
    } elseif ($existing -and $existing.Status -in @("Completed","CompletedWithWarnings")) {
        # A prior run already finished successfully (e.g. the LAST
        # orchestrator process hit -TimeoutMinutes and exited while the
        # upgrade itself kept going and completed on Server B in the
        # meantime). Re-staging/re-kicking-off setup.exe on an
        # already-upgraded server would be pointless and confusing -
        # instead resume straight into the monitoring loop, which will
        # detect the terminal status on its very first poll and print the
        # final summary immediately, without touching anything on Server B.
        $resumeExisting = $true
        # PROMINENT, EXPLICIT banner (2026-07-20, real-run feedback: the
        # single log line that used to be here didn't clearly enough state
        # "the target OS is already on the upgraded version, nothing was
        # done this run" - it read as an internal orchestration detail, not
        # an unmistakable answer to "did this server already get
        # upgraded?"). Uses the LIVE-queried OS caption/build above (most
        # trustworthy), falling back to the stored registry values only if
        # that live query itself failed.
        $liveOsText = if ($existing.LiveOSCaption) { "$($existing.LiveOSCaption) (build $($existing.LiveBuild))" } elseif ($existing.PostUpgradeOSCaption) { "$($existing.PostUpgradeOSCaption) (registry value, live re-check failed)" } else { "(could not be determined)" }
        Write-Log "====================================================================" "SUCCESS"
        Write-Log " $TargetComputer HAS A PRIOR COMPLETION RECORD - NO UPGRADE ACTION TAKEN THIS RUN. Live verification follows." "INFO"
        Write-Log "====================================================================" "SUCCESS"
        Write-Log " Current OS (live check)   : $liveOsText" "SUCCESS"
        Write-Log " Prior run outcome         : Status=$($existing.Status) (Phase=$($existing.Phase) '$($existing.PhaseName)')" "SUCCESS"
        Write-Log " Prior run last updated    : $(if ($existing.LastUpdated) { $existing.LastUpdated } else { '(not recorded)' })" "SUCCESS"
        Write-Log "====================================================================" "SUCCESS"
        Write-Log "Skipping re-stage/re-kickoff entirely - resuming will just report this existing outcome below." "SUCCESS"
    } elseif ($existing -and $existing.Status -eq "InProgress" -and [int]$existing.Phase -ge 1) {
        Write-Log "$TargetComputer reports Status=InProgress (Phase=$($existing.Phase) '$($existing.PhaseName)') but shows NO real activity (no setup process, setupact.log age=$([math]::Round($existing.PantherAgeMin,1)) min) - treating as a STALE prior attempt, not a genuine resume. Proceeding with a normal stage+kickoff; Start-TargetUpgrade.ps1's own stale-attempt cleanup (Section 1b) will reset and restart fresh." "WARN"
    }
} catch {
    Write-Log "Could not pre-check existing upgrade state on $TargetComputer (non-blocking, assuming none): $_" "WARN"
}

# Moved here from its original "Section 4 - Monitoring Loop Functions" spot
# (2026-07-24) - Section 3 below now also uses this during its Stage 1/2
# blocking-call spinner (to show a real percentage), and PowerShell does
# NOT hoist function definitions - a function is only callable once its
# `function` statement has actually executed in the script's linear
# top-to-bottom flow, so it MUST be defined before Section 3, not after.
function Read-RemoteFileWithTimeout {
    <#
    Reads a remote file (typically over an admin share, e.g. \\ServerB\D$\...)
    with a hard timeout via a background job, since a straight Test-Path/
    Get-Content against an unreachable or rebooting host can otherwise hang
    for the full SMB negotiation timeout.
    #>
    param([string]$Path, [int]$TimeoutSec = 5, [ref]$ErrorDetail)
    $job = Start-Job -ScriptBlock {
        param($p)
        if (-not (Test-Path $p)) { throw "Path not found or not accessible: $p" }
        Get-Content -Path $p -Raw -ErrorAction Stop
    } -ArgumentList $Path
    try {
        if (Wait-Job -Job $job -Timeout $TimeoutSec) {
            $jobErr = $null
            $result = Receive-Job -Job $job -ErrorVariable jobErr -ErrorAction SilentlyContinue
            if ($jobErr -and $ErrorDetail) { $ErrorDetail.Value = $jobErr[0].ToString() }
            return $result
        }
        if ($ErrorDetail) { $ErrorDetail.Value = "Timed out after ${TimeoutSec}s reading '$Path' (SMB/network may be slow, blocked, or the admin share isn't reachable)." }
        return $null
    } finally {
        Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Read-RemoteStatusJsonViaWinRM {
    param(
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Cred,
        [string]$JsonPath,
        [ValidateSet("Http","Https","HttpsSkipCert")][string]$Transport,
        [int]$TimeoutSec = 15,
        [ref]$ErrorDetail
    )

    $job = Start-Job -ScriptBlock {
        param($cn, $credential, $path, $transport)
        $invokeParams = @{ ComputerName = $cn; ErrorAction = "Stop" }
        if ($credential) {
            $invokeParams["Credential"] = $credential
            $invokeParams["Authentication"] = "Negotiate"
        }
        switch ($transport) {
            "Https" {
                $invokeParams["UseSSL"] = $true
                $invokeParams["Port"] = 5986
            }
            "HttpsSkipCert" {
                $invokeParams["UseSSL"] = $true
                $invokeParams["Port"] = 5986
                $invokeParams["SessionOption"] = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
            }
        }
        Invoke-Command @invokeParams -ScriptBlock {
            param($statusPath)
            if (-not (Test-Path $statusPath)) {
                throw "Target status JSON does not exist: $statusPath"
            }
            Get-Content -Path $statusPath -Raw -ErrorAction Stop
        } -ArgumentList $path
    } -ArgumentList $ComputerName, $Cred, $JsonPath, $Transport

    try {
        if (Wait-Job -Job $job -Timeout $TimeoutSec) {
            $jobError = $null
            $raw = Receive-Job -Job $job -ErrorVariable jobError -ErrorAction SilentlyContinue
            if ($jobError -and $ErrorDetail) { $ErrorDetail.Value = $jobError[0].ToString() }
            if ($raw) { return ($raw -join [Environment]::NewLine) }
            return $null
        }
        if ($ErrorDetail) { $ErrorDetail.Value = "Timed out after ${TimeoutSec}s reading '$JsonPath' through WinRM." }
        return $null
    } finally {
        Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# SECTION 3 - STAGE FILES + KICK OFF THE UPGRADE ON SERVER B
# =============================================================================
$upgradeKickoffOk = $resumeExisting
if (-not $resumeExisting) {
try {
    $script:LastProducerStatus = $null
    $script:LastProducerReadAtUtc = $null
    $script:ProducerCacheRecovered = $false
    Write-LocalStatusMirror
    Write-Log "Opening PSSession to $TargetComputer..."
    $session = New-PSSession @sessionParams

    Invoke-Command -Session $session -ScriptBlock {
        param($StagingPath)
        New-Item -ItemType Directory -Path $StagingPath -Force | Out-Null
    } -ArgumentList $RemoteStagingPath | Out-Null

    Write-Log "Copying target-side files to $($TargetComputer):$RemoteStagingPath ..."
    # Copy ONLY the 5 named required files (not a wildcard "*") - this is what
    # guarantees just the 6 target-side files are staged on Server B even when
    # -SourceFilesPath points at a flat folder that also contains this very
    # orchestrator script (or any other unrelated files) alongside them.
    foreach ($f in $requiredFiles) {
        Copy-Item -Path (Join-Path $SourceFilesPath $f) -Destination $RemoteStagingPath -ToSession $session -Force
    }

    # Stage optional companions (e.g. LGPO.exe) only if actually present
    # locally - never fatal when missing.
    foreach ($f in $optionalFiles) {
        $optPath = Join-Path $SourceFilesPath $f
        if (Test-Path $optPath) {
            Copy-Item -Path $optPath -Destination $RemoteStagingPath -ToSession $session -Force
            Write-Log "Optional companion '$f' found and staged to $TargetComputer."
        } else {
            Write-Log "Optional companion '$f' not found in $SourceFilesPath - continuing without it (GPO backup will fall back to robocopy/secedit only)." "WARN"
        }
    }

    Write-Log "Launching Start-TargetUpgrade.ps1 on $TargetComputer (pre-checks + backup + ISO mount + setup.exe kickoff)..."
    $remoteArgs = @{
        IsoFolder             = $IsoFolder
        MinFreeSpaceGB        = $MinFreeSpaceGB
        BackupRoot            = $BackupRoot
        StatusJsonPath        = $StatusJsonPath
        RetentionDays         = $RetentionDays
        DisableAutoCleanup    = [bool]$DisableAutoCleanup
        SkipPatchCheckLab     = [bool]$SkipPatchCheckLab
        SkipSystemStateBackup = [bool]$SkipSystemStateBackup
        SkipOrphanedProfileCheck = [bool]$SkipOrphanedProfileCheck
        SkipUserProfileCountCheck = [bool]$SkipUserProfileCountCheck
        SkipPendingFileRenameCheck = [bool]$SkipPendingFileRenameCheck
        MinVMwareToolsVersion = $MinVMwareToolsVersion
        UseControlledReboot   = [bool]$UseControlledReboot
        MaxPatchAgeDays       = $MaxPatchAgeDays
    }

    $remoteJob = Invoke-Command -Session $session -AsJob -ScriptBlock {
        # NOTE: the second parameter is deliberately named $ArgMap, NOT $Args -
        # "$Args" collides with PowerShell's automatic/reserved $args variable,
        # which causes -ArgumentList binding to FAIL SILENTLY (no error, the
        # value just never arrives) and every pass-through parameter below
        # (-IsoFolder, -RetentionDays, -SkipPatchCheckLab, etc.) would quietly
        # be dropped, leaving Start-TargetUpgrade.ps1 running on its own
        # built-in defaults regardless of what was passed to this script.
        param($StagingPath, $ArgMap)
        Set-Location $StagingPath
        $splat = @{}
        foreach ($k in $ArgMap.Keys) {
            if ($ArgMap[$k] -is [bool]) { if ($ArgMap[$k]) { $splat[$k] = $true } } else { $splat[$k] = $ArgMap[$k] }
        }
        try {
            & "$StagingPath\Start-TargetUpgrade.ps1" @splat
            $runId = (Get-ItemProperty "HKLM:\SOFTWARE\OSUpgradeAutomation" -Name RunId -ErrorAction Stop).RunId
            [pscustomobject]@{ Success = $true; Error = $null; RunId = $runId }
        } catch {
            [pscustomobject]@{ Success = $false; Error = $_.Exception.Message }
        }
    } -ArgumentList $RemoteStagingPath, $remoteArgs

    # Stage 1/2 (prechecks + backup) run entirely inside this ONE blocking
    # call, with zero polling/GUI feedback from the orchestrator itself for
    # however many minutes it takes - the plain scrolling console text (via
    # Server B's own Write-Log/Write-Host, streamed back live) was the only
    # visible sign of life. -AsJob + a periodic Receive-Job (WITHOUT -Keep,
    # so each call only returns records NOT already returned - no
    # duplicated re-printing) preserves that same live text streaming
    # (Receive-Job replays Write-Host/Warning/Verbose through their normal
    # streams, so it still prints exactly as before) while ALSO letting this
    # loop draw a spinner + elapsed-time indicator on the GUI side in
    # between drains, so it's clear something is actively happening even
    # during the several-minute gaps between log lines (e.g. during a long
    # DISM health scan or registry hive backup).
    $spinnerChars = @('|','/','-','\')
    $spinnerIdx   = 0
    $stage12Start = Get-Date
    $allReceived  = @()
    $stage12Pct = $null
    $stage12StagePct = $null
    $stage12IsCached = $false
    $stage12PhaseName = $null
    $stage12ReadWarningLogged = $false
    $stage12LastReadAt = [datetime]::MinValue
    $driveLetter = ($StatusJsonPath -split ':')[0]
    $stage12UncPath = "\\$TargetComputer\$driveLetter`$\$(($StatusJsonPath -split ':', 2)[1].TrimStart('\'))"
    while ($remoteJob.State -eq 'Running') {
        if (((Get-Date) - $stage12Start).TotalMinutes -ge $TimeoutMinutes) {
            Write-Log "Kickoff exceeded $TimeoutMinutes minutes at '$stage12PhaseName' ($stage12Pct% overall). Kindly check the target and its logs; this is not a verified Setup failure." "ERROR"
            throw "Precheck/backup/kickoff timed out. Last phase: $stage12PhaseName."
        }
        $received = Receive-Job -Job $remoteJob -ErrorAction SilentlyContinue
        if ($received) { $allReceived += $received }
        if (((Get-Date) - $stage12LastReadAt).TotalSeconds -ge $PollIntervalSeconds) {
            $stage12LastReadAt = Get-Date
            $stage12ReadError = $null
            $stage12Source = "File($stage12UncPath)"
            $rawStatus = Read-RemoteFileWithTimeout -Path $stage12UncPath -TimeoutSec 5 -ErrorDetail ([ref]$stage12ReadError)
            if (-not $rawStatus) {
                $stage12Source = "WinRM($StatusJsonPath)"
                $rawStatus = Read-RemoteStatusJsonViaWinRM -ComputerName $TargetComputer -Cred $Credential `
                    -JsonPath $StatusJsonPath -Transport $script:WinRMTransport -ErrorDetail ([ref]$stage12ReadError)
            }
            if ($rawStatus) {
                try {
                    $parsedStatus = $rawStatus | ConvertFrom-Json
                    if ($null -eq $parsedStatus.Phase -or $null -eq $parsedStatus.PercentComplete) {
                        throw "Target JSON has no phase or percentage yet."
                    }
                    if ($existing.RunId -and $parsedStatus.RunId -eq $existing.RunId) {
                        throw "Status still belongs to the prior run; waiting for the new kickoff to publish."
                    }
                    if ($null -ne $parsedStatus.PercentComplete) { $stage12Pct = [int]$parsedStatus.PercentComplete }
                    $stage12StagePct = $parsedStatus.StagePercentComplete
                    $stage12IsCached = $false
                    if ($parsedStatus.PhaseName) { $stage12PhaseName = $parsedStatus.PhaseName }
                    $stage12Observation = [pscustomobject]@{
                        PingOk = $null; WinRmOk = $true; Mode = "ActivePolling"; Source = $stage12Source
                    }
                    Write-LocalStatusMirror -ProducerStatus $parsedStatus -ObservationStatus $stage12Observation
                    $stage12ReadWarningLogged = $false
                } catch {
                    $stage12ReadError = $_.Exception.Message
                    $rawStatus = $null
                }
            }
            if (-not $rawStatus) {
                $stage12IsCached = $true
                $stage12Observation = [pscustomobject]@{
                    PingOk = $null; WinRmOk = $null; Mode = "StatusUnavailable"; Source = $stage12Source
                }
                Write-LocalStatusMirror -ObservationStatus $stage12Observation -ObservationError $stage12ReadError
                if (-not $stage12ReadWarningLogged) {
                    Write-Log "Precheck/backup status unavailable through SMB and WinRM: $stage12ReadError. Retaining the last percentage and retrying." "WARN"
                    $stage12ReadWarningLogged = $true
                }
            }
        }
        $elapsed = (Get-Date) - $stage12Start
        $pctPrefix = if ($null -ne $stage12Pct) { "[Overall $stage12Pct%" } else { "[Awaiting target status" }
        if ($null -ne $stage12StagePct) { $pctPrefix += "; stage $stage12StagePct%" }
        if ($stage12IsCached -and $null -ne $stage12Pct) { $pctPrefix += "; cached" }
        $pctPrefix += "] "
        $phaseSuffix = if ($stage12PhaseName) { " ($stage12PhaseName)" } else { "" }
        $progressParams = @{
            Activity = "Stage 1/3-2/3: Pre-Upgrade Assessment + Backup running on $TargetComputer"
            Status   = "$($spinnerChars[$spinnerIdx % 4]) ${pctPrefix}Elapsed: $($elapsed.ToString('mm\:ss'))$phaseSuffix - this can take several minutes (DISM scan, registry/GPO backup, etc.). See the scrolling [INFO]/[PASS]/[WARN] log lines printing below this bar for live step-by-step detail."
        }
        if ($null -ne $stage12Pct) { $progressParams["PercentComplete"] = $stage12Pct }
        Write-Progress @progressParams
        $spinnerIdx++
        Start-Sleep -Seconds 1
    }
    Write-Progress -Activity "Stage 1/3-2/3: Pre-Upgrade Assessment + Backup running on $TargetComputer" -Completed
    $received = Receive-Job -Job $remoteJob -ErrorAction SilentlyContinue
    if ($received) { $allReceived += $received }
    Remove-Job -Job $remoteJob -Force -ErrorAction SilentlyContinue
    # Write-Host/Warning/Verbose lines don't produce pipeline objects, so the
    # genuine [pscustomobject]@{Success;Error} return value is the only
    # thing in $allReceived with a "Success" property - pick that one out.
    $remoteResult = $allReceived | Where-Object { $_.PSObject.Properties.Name -contains 'Success' } | Select-Object -Last 1
    if (-not $remoteResult) {
        if ($script:LastProducerStatus -and [int]$script:LastProducerStatus.Phase -ge 3 -and $script:LastProducerStatus.Status -eq "InProgress") {
            Write-Log "Kickoff connection ended after the target entered Setup. Switching to bounded monitoring to distinguish reboot, interruption, and completion; Setup will not be relaunched." "WARN"
            $remoteResult = [pscustomobject]@{ Success = $true; Error = $null }
        } else {
            $remoteResult = [pscustomobject]@{ Success = $false; Error = "Job '$($remoteJob.Name)' ended in state '$($remoteJob.State)' without returning a result - check Server B's own logs (C:\ProgramData\OSUpgradeAutomation\Logs) for what happened." }
        }
    }

    if (-not $remoteResult.Success) {
        # --- Graceful stop -----------------------------------------------------
        # Deliberately does NOT re-throw the raw exception here (that produces a
        # noisy PowerShell stack trace on Server A's console, as seen in real
        # test runs). Instead: log the failure, print a clean actionable banner
        # (with SPECIFIC extra guidance when a pending reboot is the cause - the
        # most common recoverable case), and fall through to a controlled,
        # non-throwing stop (see the "$upgradeKickoffOk" check further below).
        Write-Log "Pre-upgrade assessment or kickoff FAILED on $TargetComputer." "ERROR"

        $reasons = @($remoteResult.Error -split '\s*\|\s*' | Where-Object { $_ })
        $rebootPending  = $remoteResult.Error -match '(?i)pending reboot|PendingFileRenameOperations|RebootPending|RebootRequired'
        $orphanedProfiles = $remoteResult.Error -match '(?i)orphaned profile SID|Orphaned local user profiles'

        Write-Host ""
        Write-Log "====================================================================" "ERROR"
        if ($rebootPending) {
            Write-Log " UPGRADE NOT STARTED - A REBOOT IS PENDING ON $TargetComputer" "ERROR"
        } elseif ($orphanedProfiles) {
            Write-Log " UPGRADE NOT STARTED - ORPHANED LOCAL USER PROFILE(S) ON $TargetComputer" "ERROR"
        } else {
            Write-Log " UPGRADE NOT STARTED - PRE-UPGRADE ASSESSMENT FAILED ON $TargetComputer" "ERROR"
        }
        Write-Log "====================================================================" "ERROR"
        Write-Log " Reason(s):" "ERROR"
        foreach ($r in $reasons) { Write-Log "   - $r" "ERROR" }
        Write-Host ""

        # Rebuilt from $PSBoundParameters (never hardcoded) so the hint always
        # mirrors exactly what was actually passed on THIS run - drop a flag
        # and it disappears from the hint too. Rendered per argument TYPE so the
        # result is genuinely pasteable: switches as bare flags, numbers
        # unquoted, strings quoted, and a credential as $cred (a PSCredential
        # object cannot be expressed on a command line at all).
        $reRunNeedsCred = $false
        $reRunFlags = foreach ($k in $PSBoundParameters.Keys) {
            if ($k -eq 'TargetComputer') { continue }
            $v = $PSBoundParameters[$k]
            if ($v -is [System.Management.Automation.SwitchParameter] -or $v -is [bool]) {
                if ($v) { "-$k" }
            } elseif ($v -is [System.Management.Automation.PSCredential]) {
                $reRunNeedsCred = $true
                "-$k `$cred"
            } elseif ($v -is [string]) {
                "-$k `"$v`""
            } else {
                "-$k $v"
            }
        }
        # ".\script.ps1" only works when the shell is actually sitting in the
        # script's folder; otherwise emit a call-operator + full path so the
        # line is pasteable from wherever the operator happens to be.
        $inScriptDir = ((Get-Location).Path.TrimEnd('\')) -ieq ($PSScriptRoot.TrimEnd('\'))
        $scriptRef = if ($inScriptDir) { ".\$($MyInvocation.MyCommand.Name)" } else { "& `"$PSCommandPath`"" }
        $reRunCommand = "$scriptRef -TargetComputer `"$TargetComputer`" $($reRunFlags -join ' ')".TrimEnd()
        $reRunCredHint = if ($reRunNeedsCred) { "`$cred = Get-Credential    # the same account used for this run" } else { $null }

        if ($rebootPending) {
            Write-Log "ACTION REQUIRED:" "WARN"
            Write-Log "   1. Reboot $TargetComputer now (console/RDP, or from Server A: Restart-Computer -ComputerName $TargetComputer -Force)." "WARN"
            Write-Log "   2. Wait for $TargetComputer to fully come back online." "WARN"
            Write-Log "   3. Re-run this exact command again - no other cleanup is needed:" "WARN"
            if ($reRunCredHint) { Write-Log "        $reRunCredHint" "WARN" }
            Write-Log "        $reRunCommand" "WARN"
            Write-Log "   If only PendingFileRenameOperations persists after investigation, -SkipPendingFileRenameCheck can explicitly bypass that gate. It does NOT bypass CBS/Windows Update reboot requirements or clear the queue." "WARN"
        } elseif ($orphanedProfiles) {
            $orphanCleanupPath = Join-Path $RemoteStagingPath "Remove-OrphanedProfiles.ps1"
            Write-Log "ACTION REQUIRED:" "WARN"
            Write-Log "   1. A ready-to-run cleanup script has been generated ON $TargetComputer at:" "WARN"
            Write-Log "        $orphanCleanupPath" "WARN"
            Write-Log "      Run it there in an ELEVATED PowerShell (it lists what it will remove" "WARN"
            Write-Log "      and asks you to confirm with Y or YES; add -Force to skip that prompt):" "WARN"
            Write-Log "        powershell.exe -ExecutionPolicy Bypass -File `"$orphanCleanupPath`"" "WARN"
            Write-Log "      Per-SID and copy/paste bulk alternatives were also printed in the" "WARN"
            Write-Log "      pre-check output above (Options 1 and 2) if you prefer those." "WARN"
            Write-Log "   2. It removes the ProfileList REGISTRY entries, and asks separately" "WARN"
            Write-Log "      whether to also delete the C:\Users profile FOLDERS. Answer N to" "WARN"
            Write-Log "      that second prompt to keep the user data - the pre-check passes" "WARN"
            Write-Log "      either way; folder deletion is permanent and cannot be undone." "WARN"
            Write-Log "   3. Re-run the OS upgrade with this exact command once cleanup is done:" "WARN"
            if ($reRunCredHint) { Write-Log "        $reRunCredHint" "WARN" }
            Write-Log "        $reRunCommand" "WARN"
            Write-Log "      Alternatively, after accepting the migration risk, re-run with -SkipOrphanedProfileCheck. This bypasses only orphan SID resolution; profile inventory and other safety gates still run." "WARN"
            Write-Log "      Nothing was changed on $TargetComputer this run (no backup, no ISO" "WARN"
            Write-Log "      mount, no setup.exe) - it is safe to simply retry." "WARN"
        } else {
            Write-Log "ACTION REQUIRED: Resolve the reason(s) listed above on $TargetComputer, then re-run this same command. Nothing was changed on $TargetComputer (no backup, no ISO mount, no setup.exe) - it is safe to simply retry once fixed." "WARN"
            if ($reRunCredHint) { Write-Log "   $reRunCredHint" "WARN" }
            Write-Log "   Re-run command: $reRunCommand" "WARN"
        }
        Write-Log "====================================================================" "ERROR"
        Write-Log "Full pre-check report: $BackupRoot\PreCheckReport_*.log (or C:\ProgramData\OSUpgradeAutomation\Logs if the backup drive was unreachable) on $TargetComputer." "ERROR"

        # Deliberately just falls through here (no throw/exit) - $upgradeKickoffOk
        # stays $false, the outer try's "finally" still cleans up the PSSession
        # normally, and the "if (-not $upgradeKickoffOk) { return }" check right
        # after the try/finally block performs the actual graceful stop.
    } else {
        $upgradeKickoffOk = $true
        Write-Log "Setup-stage handoff received from $TargetComputer - closing the kickoff session. Monitoring will verify Setup liveness and completion independently; multiple reboots may follow."
    }
} finally {
    if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
}
}

if (-not $upgradeKickoffOk) { return }

# =============================================================================
# SECTION 4 - MONITORING LOOP FUNCTIONS
# =============================================================================

function Get-RemoteUpgradeObservation {
    param(
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Cred,
        [ValidateSet("Http","Https","HttpsSkipCert")][string]$Transport,
        [int]$TimeoutSec = 15,
        [ref]$ErrorDetail,
        [string]$JsonPath = "",
        [switch]$RefreshMonitor
    )
    $job = Start-Job -ScriptBlock {
        param($cn, $credential, $transport, $jsonPath, $refreshMonitor)
        $p = @{ ComputerName = $cn; ErrorAction = "Stop" }
        if ($credential) {
            $p["Credential"] = $credential
            $p["Authentication"] = "Negotiate"
        }
        if ($transport -ne "Http") { $p["UseSSL"] = $true; $p["Port"] = 5986 }
        $optionArgs = @{ OpenTimeout = 5000; OperationTimeout = 10000 }
        if ($transport -eq "HttpsSkipCert") {
            $optionArgs["SkipCACheck"] = $true
            $optionArgs["SkipCNCheck"] = $true
            $optionArgs["SkipRevocationCheck"] = $true
        }
        $p["SessionOption"] = New-PSSessionOption @optionArgs
        Invoke-Command @p -ScriptBlock {
            param($statusPath, [bool]$allowMonitorRefresh)
            $ErrorActionPreference = "Stop"
            $basePath = "C:\ProgramData\OSUpgradeAutomation"
            $registry = Get-ItemProperty "HKLM:\SOFTWARE\OSUpgradeAutomation" -ErrorAction Stop
            if (-not $statusPath) { $statusPath = $registry.StatusJsonPath }
            $record = $null
            $readWarning = $null
            try {
                if (-not $statusPath) { throw "The target has not recorded its status JSON path." }
                $record = Get-Content -LiteralPath $statusPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if (-not $record.RunId -or $record.RunId -ne $registry.RunId -or $null -eq $record.Phase) {
                    throw "Status JSON is incomplete or belongs to a different run."
                }
            } catch {
                $readWarning = "Using registry fallback because target JSON could not be used: $($_.Exception.Message)"
                $properties = [ordered]@{}
                foreach ($property in $registry.PSObject.Properties) {
                    if ($property.Name -notmatch '^PS') { $properties[$property.Name] = $property.Value }
                }
                $record = [pscustomobject]$properties
            }
            $version = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop
            $setup = Get-ItemProperty "HKLM:\SYSTEM\Setup" -ErrorAction Stop
            $live = [ordered]@{
                CurrentBuild = $version.CurrentBuildNumber
                SystemSetupInProgress = $setup.SystemSetupInProgress
                OOBEInProgress = $setup.OOBEInProgress
                SetupRunning = [bool](Get-Process -Name "setup", "setuphost", "setupprep" -ErrorAction SilentlyContinue)
                LastBootUpTimeUtc = $null
                MonitorState = $null
                MonitorRecovery = $null
                MonitorRecoveryError = $null
                ProbeWarning = $readWarning
            }
            if ($allowMonitorRefresh -and $record.Status -eq "InProgress" -and [int]$record.Phase -ge 3 -and [int]$record.Phase -le 7) {
                try {
                    $ageSeconds = if ($record.StatusUpdatedAtUtc) {
                        ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($record.StatusUpdatedAtUtc)).TotalSeconds
                    } else { [double]::PositiveInfinity }
                    $needsValidation = $record.TargetBuild -and $live.CurrentBuild -eq $record.TargetBuild -and
                        $null -ne $live.SystemSetupInProgress -and $live.SystemSetupInProgress -eq 0
                    $task = Get-ScheduledTask -TaskName "OSUpgradePhaseMonitor" -ErrorAction SilentlyContinue
                    $live["MonitorState"] = if ($task) { [string]$task.State } else { "Missing" }
                    if (-not $task -or $ageSeconds -ge 120 -or $needsValidation) {
                        if (-not $task) {
                            $monitorPath = Join-Path $basePath "Scripts\Update-UpgradeStatus.ps1"
                            if (-not (Test-Path -LiteralPath $monitorPath)) { throw "Monitor script missing: $monitorPath" }
                            $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$monitorPath`""
                            $timer = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
                                -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3)
                            $startup = New-ScheduledTaskTrigger -AtStartup
                            $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
                            $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
                                -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
                            Register-ScheduledTask -TaskName "OSUpgradePhaseMonitor" -Action $action `
                                -Trigger @($timer, $startup) -Principal $principal -Settings $settings | Out-Null
                            $live["MonitorRecovery"] = "Recreated missing status monitor (Setup was not relaunched)."
                        }
                        if ($task -and [string]$task.State -eq "Disabled") { throw "OSUpgradePhaseMonitor is disabled; enable the monitor task after reviewing policy." }
                        if (-not $task -or [string]$task.State -ne "Running") {
                            Start-ScheduledTask -TaskName "OSUpgradePhaseMonitor" -ErrorAction Stop
                            $live["MonitorRecovery"] += " Requested immediate status/validation refresh."
                        }
                    }
                } catch {
                    $live["MonitorRecoveryError"] = "Cannot refresh the target status monitor: $($_.Exception.Message)"
                }
            }
            [pscustomobject]@{ ProducerStatus = [pscustomobject]$record; LiveState = [pscustomobject]$live }
        } -ArgumentList $jsonPath, $refreshMonitor
    } -ArgumentList $ComputerName, $Cred, $Transport, $JsonPath, ([bool]$RefreshMonitor)
    try {
        if (Wait-Job -Job $job -Timeout $TimeoutSec) {
            $jobError = $null
            $result = Receive-Job -Job $job -ErrorVariable jobError -ErrorAction SilentlyContinue
            if ($jobError -and $ErrorDetail) { $ErrorDetail.Value = $jobError[0].ToString() }
            return $result
        }
        if ($ErrorDetail) { $ErrorDetail.Value = "Live WinRM status/build probe timed out after ${TimeoutSec}s." }
        return $null
    } finally {
        Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Add-UpgradeObservation {
    param($Record, [bool]$PingOk, [bool]$WinRmOk, [string]$Source, $LiveState, [switch]$LogOnly)
    if ($null -eq $Record -or $Record.Phase -notin @(1,2,3,4,5,6,7,99) -or
        $Record.Status -notin @("InProgress", "Completed", "CompletedWithWarnings", "Failed")) { return $null }
    if ($script:ExpectedRunId -and $Record.RunId -ne $script:ExpectedRunId) {
        Write-Log "Rejected $Source status from a different run (expected $script:ExpectedRunId, received $($Record.RunId))." "WARN" -LogOnly:$LogOnly
        return $null
    }
    if ($script:LastProducerStatus -and $Record.RunId -eq $script:LastProducerStatus.RunId) {
        $priorBoot = [DateTimeOffset]::MinValue
        $currentBoot = [DateTimeOffset]::MinValue
        $hasBootTimes = [DateTimeOffset]::TryParse([string]$Record.LastObservedBootTimeUtc, [ref]$currentBoot) -and
            [DateTimeOffset]::TryParse([string]$script:LastProducerStatus.LastObservedBootTimeUtc, [ref]$priorBoot)
        if ($hasBootTimes -and $currentBoot -lt $priorBoot) {
            Write-Log "Rejected $Source status from a boot older than the last accepted target boot." "WARN" -LogOnly
            return $null
        }
        if ($null -ne $Record.Sequence -and [long]$Record.Sequence -lt [long]$script:LastProducerStatus.Sequence) {
            if (-not $hasBootTimes -or $currentBoot -le $priorBoot) {
                Write-Log "Rejected older $Source status sequence $($Record.Sequence); last accepted=$($script:LastProducerStatus.Sequence)." "WARN" -LogOnly
                return $null
            }
            Write-Log "Accepted same-run status after a confirmed new boot despite a migrated registry sequence ($($script:LastProducerStatus.Sequence) -> $($Record.Sequence))." "INFO" -LogOnly:$LogOnly
        }
    }
    if ($null -ne $Record.SetupPhaseHistory) {
        $Record.SetupPhaseHistory = @(ConvertFrom-UpgradePhaseHistory -History $Record.SetupPhaseHistory)
    }
    $Record | Add-Member -NotePropertyMembers @{
        PingOk = $PingOk; WinRmOk = $WinRmOk; Source = $Source; LiveState = $LiveState
        Mode = $(if ($WinRmOk) { "ActivePolling" } else { "Heartbeat" })
    } -Force
    return $Record
}

function Get-UpgradeHealthWarning {
    param($Status, $LastProducer, [DateTimeOffset]$LastAdvanceAtUtc, [int]$StaleMinutes, [DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow)
    if ($Status.Status -in @("Completed", "CompletedWithWarnings", "Failed")) { return $null }
    if ($Status.LiveState.MonitorRecoveryError) { return $Status.LiveState.MonitorRecoveryError }
    if ($Status.MonitorLastError) { return "Target status monitor error: $($Status.MonitorLastError). Review the target monitor log; retry is pending." }
    if ($Status.SetupProcessMissingSinceUtc -and $Status.Status -eq "InProgress") { return $Status.Notes }
    $ageSeconds = ($NowUtc - $LastAdvanceAtUtc).TotalSeconds
    if ($LastProducer.StatusUpdatedAtUtc) {
        $stamp = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($LastProducer.StatusUpdatedAtUtc, [ref]$stamp)) {
            $ageSeconds = [math]::Max($ageSeconds, ($NowUtc - $stamp).TotalSeconds)
        } else { return "Target status timestamp is invalid; freshness cannot be verified. Check the target monitor." }
    }
    if ($ageSeconds -ge $StaleMinutes * 60) {
        $buildContext = if ($LastProducer.TargetBuild -and $Status.LiveState.CurrentBuild -eq $LastProducer.TargetBuild) {
            " The live OS already reports target build $($LastProducer.TargetBuild); Setup/validation completion still needs verification."
        } else { "" }
        return "ATTENTION: target status is stale/unavailable for $([math]::Round($ageSeconds / 60, 1)) min. Last confirmed phase='$($LastProducer.PhaseName)', overall=$($LastProducer.PercentComplete)%. Connectivity=$($Status.Mode).$buildContext Kindly check the target and OSUpgradePhaseMonitor; a reboot, failure, or telemetry outage is possible. Completion is NOT confirmed."
    }
    return $null
}

function Get-UpgradeCompletionCheck {
    param($Status, [string]$TargetBuild)
    $reason = if ($Status.Status -notin @("Completed", "CompletedWithWarnings") -or $Status.Mode -ne "ActivePolling") {
        "A terminal target status and active WinRM are required."
    } elseif (-not $TargetBuild) {
        "Expected target build is missing."
    } elseif (-not $Status.LiveState -or -not $Status.LiveState.CurrentBuild) {
        "Live OS build/Setup flags could not be read; success cannot be independently confirmed."
    } elseif ($Status.LiveState.CurrentBuild -ne $TargetBuild) {
        "Live build $($Status.LiveState.CurrentBuild) does not match target $TargetBuild."
    } elseif ($null -eq $Status.LiveState.SystemSetupInProgress -or $null -eq $Status.LiveState.OOBEInProgress) {
        "Setup completion flags are missing; an unknown flag is not zero."
    } elseif ($Status.LiveState.SystemSetupInProgress -ne 0 -or $Status.LiveState.OOBEInProgress -ne 0) {
        "Target build is present but Windows Setup/OOBE is still active."
    } else { $null }
    [pscustomobject]@{ Confirmed = (-not $reason); Reason = $reason }
}

function Wait-UpgradeCompletion {
    param(
        $InitialStatus,
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Cred,
        [ValidateSet("Http","Https","HttpsSkipCert")][string]$Transport,
        [string]$TargetBuild,
        [ValidateRange(1,600)][int]$TimeoutSeconds = 60
    )
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $candidate = $InitialStatus
    $lastStatus = $InitialStatus
    $lastReason = "Live completion has not been confirmed."
    $lastLoggedReason = ""
    $hasProbed = $false
    Write-Log "Validating update for a few seconds on $ComputerName (up to $TimeoutSeconds seconds)..."
    try {
        while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            if ($candidate) {
                $lastStatus = $candidate
                if ($candidate.Status -eq "Failed") {
                    Write-LocalStatusMirror -ProducerStatus $candidate -ObservationStatus $candidate
                    return [pscustomobject]@{ Outcome = "Failed"; Status = $candidate; Error = $candidate.Notes }
                }
                $check = Get-UpgradeCompletionCheck -Status $candidate -TargetBuild $TargetBuild
                if ($check.Confirmed) {
                    Write-LocalStatusMirror -ProducerStatus $candidate -ObservationStatus $candidate
                    return [pscustomobject]@{ Outcome = $candidate.Status; Status = $candidate; Error = $null }
                }
                $lastReason = $check.Reason
            }
            if ($lastReason -ne $lastLoggedReason) {
                Write-Log "Final validation pending: $lastReason" "INFO" -LogOnly
                $lastLoggedReason = $lastReason
            }
            $observation = [pscustomobject]@{
                Mode = "Validating"; Source = "ServerA.FinalValidation"
                PingOk = $candidate.PingOk; WinRmOk = $candidate.WinRmOk; LiveState = $candidate.LiveState
            }
            Write-LocalStatusMirror -ProducerStatus $candidate -ObservationStatus $observation -ObservationError $lastReason
            Write-Progress -Activity "Monitoring OS upgrade on $ComputerName" `
                -Status "Validating update... please wait (up to $TimeoutSeconds seconds)." -PercentComplete -1
            if ($hasProbed) {
                $delayMs = [int][math]::Min(5000, [math]::Max(0, ($TimeoutSeconds - $clock.Elapsed.TotalSeconds) * 1000))
                if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
            }
            $remainingSeconds = $TimeoutSeconds - $clock.Elapsed.TotalSeconds
            if ($remainingSeconds -lt 1) { break }
            $probeError = $null
            $remote = $null
            try {
                $remote = Get-RemoteUpgradeObservation -ComputerName $ComputerName -Cred $Cred -Transport $Transport `
                    -TimeoutSec ([int][math]::Floor([math]::Min(15, $remainingSeconds))) -ErrorDetail ([ref]$probeError)
            } catch {
                $probeError = $_.Exception.Message
            }
            $candidate = Add-UpgradeObservation -Record $remote.ProducerStatus -PingOk ([bool]$lastStatus.PingOk) `
                -WinRmOk ([bool]$remote) -Source "WinRM(FinalValidation)" -LiveState $remote.LiveState -LogOnly
            if (-not $candidate) {
                $lastReason = if ($probeError) { $probeError } else {
                    "No valid current-run status returned by WinRM (missing, older, or mismatched run data)."
                }
            }
            $hasProbed = $true
        }
    } finally {
        $clock.Stop()
    }
    $message = "Post-upgrade validation could not be confirmed within $TimeoutSeconds seconds. Expected build=$TargetBuild; last target status=$($lastStatus.Status). $lastReason Review the target and orchestrator logs, then rerun monitoring. The OS upgrade itself may have succeeded; success is NOT being assumed."
    $failedObservation = [pscustomobject]@{
        Mode = "ValidationFailed"; Source = "ServerA.FinalValidation"; HealthWarning = $message
        PingOk = $null; WinRmOk = $null
    }
    Write-LocalStatusMirror -ObservationStatus $failedObservation -ObservationError $message
    return [pscustomobject]@{ Outcome = "ValidationFailed"; Status = $lastStatus; Error = $message }
}

function Test-RemoteWinRM {
    <#
    Explicitly checks whether WinRM/PowerShell Remoting is currently reachable
    on the target - this is the signal that drives the Active-Polling <->
    Heartbeat state machine below. Reuses the transport already resolved in
    Section 1b (HTTP/5985 or HTTPS/5986) rather than re-assuming the HTTP
    default, via the same bounded-probe helper, so the recurring check and the
    up-front check can never disagree about what "reachable" means.
    #>
    param([string]$ComputerName, [System.Management.Automation.PSCredential]$Cred, [int]$TimeoutSec = 5)
    return Test-WinRMTransport -ComputerName $ComputerName -Cred $Cred `
                               -Transport $script:WinRMTransport -TimeoutSec $TimeoutSec
}

function Get-RemoteStatusViaCimDcom {
    <#
    Reads the same status fields directly out of the remote registry via
    StdRegProv, using the classic DCOM/RPC transport (New-CimSessionOption
    -Protocol Dcom) rather than the default WSMan transport. This is
    deliberately WinRM-INDEPENDENT: DCOM/RPC (port 135 + dynamic range) is a
    genuinely separate channel from WinRM (port 5985/5986), so this can
    still succeed as a secondary source even while WinRM/Active-Polling mode
    is down - matching the spec's "query via WMI/CIM/Registry" requirement
    as a channel distinct from PowerShell Remoting.
    #>
    param([string]$ComputerName, [System.Management.Automation.PSCredential]$Cred, [ref]$ErrorDetail, [int]$TimeoutSec = 8)
    $job = Start-Job -ScriptBlock {
    param($ComputerName, $Cred)
    try {
        $cimOption = New-CimSessionOption -Protocol Dcom
        $cimParams = @{ ComputerName = $ComputerName; SessionOption = $cimOption; OperationTimeoutSec = 5; ErrorAction = "Stop" }
        if ($Cred) { $cimParams["Credential"] = $Cred }
        $cimSession = New-CimSession @cimParams
        try {
            $hDefKeyLocalMachine = [uint32]2147483650
            $keyPath = "SOFTWARE\OSUpgradeAutomation"

            function Get-RegSZ($name) {
                $r = Invoke-CimMethod -CimSession $cimSession -Namespace root\default -ClassName StdRegProv -MethodName GetStringValue -OperationTimeoutSec 2 -Arguments @{ hDefKey = $hDefKeyLocalMachine; sSubKeyName = $keyPath; sValueName = $name }
                if ($r.ReturnValue -eq 0) { return $r.sValue } else { return $null }
            }
            function Get-RegDWord($name) {
                $r = Invoke-CimMethod -CimSession $cimSession -Namespace root\default -ClassName StdRegProv -MethodName GetDWORDValue -OperationTimeoutSec 2 -Arguments @{ hDefKey = $hDefKeyLocalMachine; sSubKeyName = $keyPath; sValueName = $name }
                if ($r.ReturnValue -eq 0) { return $r.uValue } else { return $null }
            }

            $obj = [ordered]@{
                SchemaVersion                = Get-RegDWord "SchemaVersion"
                RunId                        = Get-RegSZ "RunId"
                Sequence                     = Get-RegDWord "Sequence"
                ComputerName                 = $ComputerName
                Status                       = Get-RegSZ "Status"
                Phase                        = Get-RegDWord "Phase"
                PhaseName                    = Get-RegSZ "PhaseName"
                StageNumber                  = Get-RegDWord "StageNumber"
                Stage                        = Get-RegSZ "Stage"
                StagePercentComplete         = Get-RegDWord "StagePercentComplete"
                PhasePercentComplete         = Get-RegDWord "PhasePercentComplete"
                OverallPercentComplete       = Get-RegDWord "OverallPercentComplete"
                PercentComplete              = Get-RegDWord "PercentComplete"
                PercentSource                = Get-RegSZ "PercentSource"
                ProgressSource               = Get-RegSZ "ProgressSource"
                ProgressFreshness            = Get-RegSZ "ProgressFreshness"
                ProgressUpdatedAtUtc         = Get-RegSZ "ProgressUpdatedAtUtc"
                StatusUpdatedAtUtc           = Get-RegSZ "StatusUpdatedAtUtc"
                LastUpdated                  = Get-RegSZ "LastUpdated"
                StartTime                    = Get-RegSZ "StartTime"
                StartTimeUtc                 = Get-RegSZ "StartTimeUtc"
                SetupLaunchTimeUtc           = Get-RegSZ "SetupLaunchTimeUtc"
                ExpectedDisconnect           = [bool](Get-RegDWord "ExpectedDisconnect")
                RebootCount                  = Get-RegDWord "RebootCount"
                LastObservedBootTimeUtc      = Get-RegSZ "LastObservedBootTimeUtc"
                BootEvidence                 = Get-RegSZ "BootEvidence"
                RestartRequestedAtUtc        = Get-RegSZ "RestartRequestedAtUtc"
                UnexpectedRestartAtUtc       = Get-RegSZ "UnexpectedRestartAtUtc"
                SetupPhaseHistory            = Get-RegSZ "SetupPhaseHistory"
                SourceBuild                  = Get-RegSZ "SourceBuild"
                TargetBuild                  = Get-RegSZ "TargetBuild"
                SourceOSCaption              = Get-RegSZ "SourceOSCaption"
                TargetOSCaption              = Get-RegSZ "TargetOSCaption"
                Notes                        = Get-RegSZ "Notes"
                SetupLogTail                 = Get-RegSZ "SetupLogTail"
                SetupTelemetryPercent        = Get-RegDWord "SetupTelemetryPercent"
                SetupTelemetryPhase          = Get-RegDWord "SetupTelemetryPhase"
                SetupTelemetrySource         = Get-RegSZ "SetupTelemetrySource"
                SetupProcessMissingSinceUtc  = Get-RegSZ "SetupProcessMissingSinceUtc"
                SetupFailureDetectedAtUtc    = Get-RegSZ "SetupFailureDetectedAtUtc"
                MonitorLastError             = Get-RegSZ "MonitorLastError"
                VerifiedTargetBuild          = Get-RegSZ "VerifiedTargetBuild"
                CompletionEvidence           = Get-RegSZ "CompletionEvidence"
                PostUpgradeOSCaption         = Get-RegSZ "PostUpgradeOSCaption"
                ServicesComparisonResult     = Get-RegSZ "ServicesComparisonResult"
                ServicesComparisonReportPath = Get-RegSZ "ServicesComparisonReportPath"
                ServicesAttentionCount       = Get-RegDWord "ServicesAttentionCount"
                ServicesInfoCount            = Get-RegDWord "ServicesInfoCount"
                LicenseRecommendation        = Get-RegSZ "LicenseRecommendation"
                BackupFolder                 = Get-RegSZ "BackupFolder"
                SystemStateBackupPath         = Get-RegSZ "SystemStateBackupPath"
                DirtyBitCheckStatus          = Get-RegSZ "DirtyBitCheckStatus"
                UserProfileInventoryStatus   = Get-RegSZ "UserProfileInventoryStatus"
                UserProfileCount             = Get-RegDWord "UserProfileCount"
                SpecialProfileCount          = Get-RegDWord "SpecialProfileCount"
                TotalProfileCount            = Get-RegDWord "TotalProfileCount"
                LoadedUserProfileCount       = Get-RegDWord "LoadedUserProfileCount"
                UserProfileInventoryPath     = Get-RegSZ "UserProfileInventoryPath"
                OrphanedProfileCheckStatus   = Get-RegSZ "OrphanedProfileCheckStatus"
                OrphanedProfileCount         = Get-RegDWord "OrphanedProfileCount"
                PendingFileRenameCheckStatus = Get-RegSZ "PendingFileRenameCheckStatus"
            }
            return [pscustomobject]$obj
        } finally {
            Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue
        }
    } catch { throw }
    } -ArgumentList $ComputerName, $Cred
    try {
        if (Wait-Job -Job $job -Timeout $TimeoutSec) {
            $jobError = $null
            $result = Receive-Job -Job $job -ErrorVariable jobError -ErrorAction SilentlyContinue
            if ($jobError -and $ErrorDetail) { $ErrorDetail.Value = $jobError[0].ToString() }
            return $result
        }
        if ($ErrorDetail) { $ErrorDetail.Value = "Entire DCOM status read timed out after ${TimeoutSec}s." }
        return $null
    } finally {
        Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Get-UpgradeStatus {
    <#
    Prefer fresh atomic JSON over SMB, then one WinRM status read, then DCOM.
    Detailed OS/recovery queries are reserved for unavailable/stale JSON and
    final verification, not run unconditionally against busy Setup hosts.
    ActivePolling means WinRM answered; Heartbeat means some other channel
    answered; Offline means none answered. These are connectivity states,
    never Setup phase determinations. ICMP is auxiliary, not a hard gate.
    #>
    param([string]$ComputerName, [System.Management.Automation.PSCredential]$Cred, [string]$JsonPath)

    $ping = New-Object System.Net.NetworkInformation.Ping
    try { $pingOk = ($ping.Send($ComputerName, 1000).Status -eq "Success") }
    catch { $pingOk = $false }
    finally { $ping.Dispose() }
    $winRmOk = Test-RemoteWinRM -ComputerName $ComputerName -Cred $Cred -TimeoutSec 10
    $mode    = if ($winRmOk) { "ActivePolling" } else { "Heartbeat" }

    $observation = $null
    $liveError = $null

    # Channel A - admin share JSON file (independent of WinRM; needs SMB/admin$ only).
    $driveLetter = ($JsonPath -split ':')[0]
    $uncPath = "\\$ComputerName\$driveLetter`$\$(($JsonPath -split ':', 2)[1].TrimStart('\'))"
    $fileErr = $null
    $fileStatus = $null
    $raw = Read-RemoteFileWithTimeout -Path $uncPath -TimeoutSec 5 -ErrorDetail ([ref]$fileErr)
    if ($raw) {
        try {
            $parsed = $raw | ConvertFrom-Json
            $fileStatus = Add-UpgradeObservation -Record $parsed -PingOk $pingOk -WinRmOk $winRmOk `
                -Source "File($uncPath)" -LiveState $observation.LiveState
            $stamp = [DateTimeOffset]::MinValue
            if ($fileStatus -and [DateTimeOffset]::TryParse($fileStatus.StatusUpdatedAtUtc, [ref]$stamp) -and
                ([DateTimeOffset]::UtcNow - $stamp).TotalSeconds -lt 120) {
                $script:fileDcomDiagLogged = $false
                $script:LiveReadFailureLogged = $false
                return $fileStatus
            }
        } catch {
            Write-Log "Status file read but could not be parsed as JSON (transient write in progress?) - will retry next poll." "WARN"
        }
    }

    if ($winRmOk) {
        $lastKnown = if ($fileStatus) { $fileStatus } else { $script:LastProducerStatus }
        $stamp = [DateTimeOffset]::MinValue
        $needsRefresh = $lastKnown.Status -eq "InProgress" -and [int]$lastKnown.Phase -ge 3 -and
            [DateTimeOffset]::TryParse([string]$lastKnown.StatusUpdatedAtUtc, [ref]$stamp) -and
            ([DateTimeOffset]::UtcNow - $stamp).TotalSeconds -ge 120
        $allowRefresh = $needsRefresh -and (-not $script:LastMonitorRefreshAtUtc -or
            ([DateTimeOffset]::UtcNow - $script:LastMonitorRefreshAtUtc).TotalSeconds -ge 60)
        if ($allowRefresh) { $script:LastMonitorRefreshAtUtc = [DateTimeOffset]::UtcNow }
        $observation = Get-RemoteUpgradeObservation -ComputerName $ComputerName -Cred $Cred -JsonPath $JsonPath `
            -Transport $script:WinRMTransport -RefreshMonitor:$allowRefresh -ErrorDetail ([ref]$liveError)
        $accepted = Add-UpgradeObservation -Record $observation.ProducerStatus -PingOk $pingOk -WinRmOk $winRmOk `
            -Source "WinRM(Status)" -LiveState $observation.LiveState
        if ($accepted) {
            $script:fileDcomDiagLogged = $false
            $script:LiveReadFailureLogged = $false
            return $accepted
        }
        if ($liveError) {
            Write-Log "WinRM status read unavailable; retaining JSON or trying DCOM: $liveError" "WARN" -LogOnly:$script:LiveReadFailureLogged
            $script:LiveReadFailureLogged = $true
        }
    }

    # Channel B - CIM over DCOM/RPC (also independent of WinRM).
    $cimErr = $null
    $cimStatus = Get-RemoteStatusViaCimDcom -ComputerName $ComputerName -Cred $Cred -ErrorDetail ([ref]$cimErr)
    $accepted = Add-UpgradeObservation -Record $cimStatus -PingOk $pingOk -WinRmOk $winRmOk `
        -Source "CIM(DCOM)" -LiveState $observation.LiveState
    if ($accepted -and (-not $fileStatus -or [long]$accepted.Sequence -ge [long]$fileStatus.Sequence)) {
        $script:fileDcomDiagLogged = $false
        return $accepted
    }
    if ($fileStatus) { return $fileStatus }

    if ($winRmOk) {
        # No payload channel yielded data. The machine is definitely alive,
        # so retain the cached producer snapshot and report the three channel
        # failures once instead of manufacturing phase or percentage data.
        # This specific combination (WinRM confirmed up, but BOTH the SMB
        # file-share AND CIM/DCOM channels came back empty) used to be
        # completely silent about WHY - it would just show "0%, no status
        # source yet" indefinitely with zero diagnostic trail, even across
        # an entire multi-hour run. Log the ACTUAL underlying reason from
        # both channels once per occurrence (not every 15s poll) so this is
        # actually debuggable instead of a black box.
        if (-not $script:fileDcomDiagLogged) {
            Write-Log "WinRM endpoint answered on $ComputerName but no status payload channel returned data. File-share reason: $(if ($fileErr) { $fileErr } else { 'no data/empty response' }) | DCOM reason: $(if ($cimErr) { $cimErr } else { 'no data/empty response' }) | WinRM read reason: $(if ($liveError) { $liveError } else { 'no data/empty response' }). Retaining the last confirmed status; an endpoint response does not prove a usable remote shell." "WARN"
            $script:fileDcomDiagLogged = $true
        }
        return [pscustomobject]@{ PingOk = $pingOk; WinRmOk = $true; Mode = $mode; Source = "WinRMOnly"; Status = "Unknown"; PhaseName = "WinRM endpoint reachable; Setup phase unconfirmed"; PercentComplete = $null; Notes = "No readable target status. WinRM: $liveError; SMB: $fileErr; DCOM: $cimErr"; TargetBuild = $null; Stage = "Stage 3/3: Windows Setup Execution"; LiveState = $observation.LiveState }
    }

    # WinRM is down too, but ping succeeded - typical during the Safe OS
    # (WinPE) blind window, where NOTHING (WinRM, SMB, DCOM) is up, OR simply
    # a normal ICMP-allowed network with no richer channel answering yet.
    if ($pingOk) {
        # Stage is explicitly set here (rather than left blank) because this
        # fallback can ONLY ever fire after setup.exe has already been
        # launched (Stage 1/2 never reach this code path at all) - so it's
        # always genuinely Stage 3, even though we can't confirm the exact
        # sub-phase. Wording calls out Safe OS/WinPE by name so it's less
        # ambiguous to a customer watching the GUI bar than a bare
        # "heartbeat only" message.
        return [pscustomobject]@{ PingOk = $true; WinRmOk = $false; Mode = "Heartbeat"; Source = "PingOnly"; Status = "Unknown"; PhaseName = "Reboot/network transition; Setup phase unconfirmed"; PercentComplete = $null; Notes = "Ping alone cannot distinguish Safe OS, normal boot, interrupted Setup, or rollback. Awaiting Setup/build evidence."; TargetBuild = $null; Stage = "Stage 3/3: Windows Setup Execution" }
    }

    # Nothing answered on ANY of the four channels. This is either a true
    # Offline/mid-reboot state, or - in an environment where ICMP is
    # blocked by policy - it could ALSO mean WinRM/SMB/DCOM are just
    # temporarily down together during a reboot; the wording below doesn't
    # assume ping is a reliable "is it down" signal on its own. Stage is set
    # for the same reason as the PingOnly branch above - this can only ever
    # fire after setup.exe has already launched.
    return [pscustomobject]@{ PingOk = $false; WinRmOk = $false; Mode = "Offline"; Source = "None"; Status = "Unknown"; PhaseName = "Target unreachable; Setup phase unconfirmed"; PercentComplete = $null; Notes = "No target channel responded. A reboot, network outage, or failure is possible; retaining the last confirmed status."; TargetBuild = $null; Stage = "Stage 3/3: Windows Setup Execution" }
}

function Show-ProgressBar {
    <#
    Renders progress via PowerShell's native Write-Progress instead of a
    manually-overwritten ASCII line. The old `\r` + Write-Host -NoNewline
    approach relies on the host terminal honoring a bare carriage return as
    "overwrite this line in place" - on hosts/redirections where that isn't
    true (e.g. output captured to a file, some remoting/CI consoles), every
    poll instead prints a brand-new line, and since PhaseName/Status/Source
    vary in length, each new render can leave fragments of the previous
    (longer) line behind - producing exactly the garbled, repeated-line
    clutter seen in practice. Write-Progress draws in its own dedicated,
    self-clearing UI region above the scrollback, so the regular Write-Log
    output (phase/mode transitions, banners) stays clean and uncluttered
    regardless of host/redirection quirks.
    #>
    param(
        [int]$PercentComplete, [string]$PhaseName, [string]$Status,
        [bool]$PingOk, [string]$Mode, [string]$Source,
        [string]$PercentSource, [string]$ProgressSource,
        [string]$ProgressFreshness, [string]$Stage
    )

    $pct = [math]::Max(0, [math]::Min(100, $PercentComplete))
    # If ping fails but some other channel confirms the host IS actually
    # reachable (Mode isn't "Offline"), showing a flat "OFFLINE" here would
    # visibly contradict "Active Polling"/"Heartbeat" right next to it - this
    # is exactly what happens in an ICMP-blocked environment, where ping
    # will NEVER succeed even though the server is fully up. Distinguish
    # "confirmed reachable via ping" from "reachable via another channel,
    # ping just didn't/couldn't answer" instead of conflating both as ONLINE
    # or falsely calling it OFFLINE.
    $pingText = if ($PingOk) { "ONLINE" } elseif ($Mode -ne "Offline") { "REACHABLE*" } else { "OFFLINE" }
    $modeText = switch ($Mode) { "ActivePolling" { "Active Polling" } "Heartbeat" { "Heartbeat" } default { "Offline" } }
    # Percentage is spelled out explicitly in -Status (not left to the native
    # graphical bar alone) - on narrow terminal widths, PowerShell's own
    # Write-Progress bar/percentage text gets clipped and can render as just
    # the fill glyphs ("[ooo") with no visible number, so the "NN%" here is
    # what actually guarantees the percentage stays readable regardless of
    # terminal width. PercentSource and ProgressFreshness are also spelled
    # out so a live MoSetup sample, a deterministic milestone, and a carried
    # value during SafeOS/WinPE cannot be confused.
    $srcText = if ($PercentSource) { $PercentSource } else { "n/a" }
    # Stage groups Phase 1 (Precheck) / Phase 2 (Backup) / Phase 3-7
    # (Windows Setup actually executing: Downlevel -> Safe OS -> First Boot
    # -> OOBE -> Completed) so it's immediately clear at a glance which of
    # the 3 broad stages is running, in addition to the granular PhaseName.
    $stageText = if ($Stage) { "$Stage - " } else { "" }
    $freshnessText = if ($ProgressFreshness) { $ProgressFreshness } else { "UnknownFreshness" }
    $progressSourceText = if ($ProgressSource) { $ProgressSource } else { "UnknownSource" }
    Write-Progress -Activity "Monitoring OS upgrade on $TargetComputer [$pingText / $modeText]" `
        -Status "$stageText[$pct% - $srcText/$freshnessText via $progressSourceText] $PhaseName (Status=$Status, observer:$Source)" `
        -PercentComplete $pct
}

# =============================================================================
# SECTION 5 - MONITORING LOOP
# WinRM disconnect handling: Server B's SafeOS/reboot phases tear down
# networking, so WinRM (used for Active Polling) WILL drop mid-run - this is
# expected, not an error. The loop below never treats a WinRM/CIM/session
# failure as fatal; Get-UpgradeStatus's "Mode" flag simply flips from
# "ActivePolling" to "Heartbeat" (ping-only) and back automatically once
# WinRM answers again - there is nothing the operator needs to do to
# "reconnect"; polling continues on the same interval throughout.
# =============================================================================
Write-Log "Entering monitoring loop (poll every $PollIntervalSeconds sec, timeout $TimeoutMinutes min)..."
Write-Log "Monitoring modes: ACTIVE (WinRM endpoint answers) / HEARTBEAT (another channel answers, WinRM probe unavailable) / OFFLINE (no channel answers). Connectivity alone does not identify a Setup phase."
$startTime      = Get-Date
$script:ExpectedRunId = if ($resumeExisting) { $existing.RunId } elseif ($remoteResult.RunId) { $remoteResult.RunId } else { $script:LastProducerStatus.RunId }
$script:LastMonitorRefreshAtUtc = [DateTimeOffset]::MinValue
$script:LiveReadFailureLogged = $false
$lastProducerKey = $null
$lastProducerAdvanceAtUtc = [DateTimeOffset]::UtcNow
$lastHealthWarningAtUtc = [DateTimeOffset]::MinValue
$lastHealthWarningKey = ""
$lastRecoveryMessage = ""
$reportedPhaseHistory = @{}
# Tracks the last CONFIRMED real Phase reading (File/CIM-DCOM) - never the
# synthetic WinRMOnly/Heartbeat/Offline fallback text ("Safe OS/WinPE
# transition or reboot in progress...") is a GUESS, not a confirmed fact -
# it has been PROVEN wrong in real runs (connectivity dropped for ~19s, then
# the real reading came back still showing 'Downlevel Phase', meaning
# Server B never actually reached Safe OS at all; the gap had some other
# cause - e.g. Setup's own internal network-stack work during Downlevel
# prep, or a transient VM/hypervisor blip). Treating that guess as if it
# were a real phase, then "transitioning" back to the real phase once data
# returns, made it look like an impossible backward phase regression (Safe
# OS -> Downlevel can NEVER genuinely happen in Windows Setup's own linear
# Downlevel->SafeOS->FirstBoot->OOBE model). Phase-change logging below now
# only ever compares against this CONFIRMED value, never the guess. Was
# initially a bare "" (making the very first "Phase change detected: '' ->
# 'X'" line look like a blank/missing value) - now explicit for clarity.
$lastConfirmedPhaseName = $null
# Set to $true for exactly one loop iteration - the first real reading
# after reconnecting from Heartbeat/Offline - so the phase-comparison logic
# below can tell "just reconnected" apart from "was already ActivePolling".
$justReconnected = $false
$lastMode       = ""
# Tracks WHEN the current Heartbeat/Offline stretch began, so the
# "connectivity RESTORED" message can report how long it actually lasted -
# a 19-second gap and a 6-minute gap are VERY different things (one is
# almost certainly just a flaky poll, the other is consistent with a real
# Safe OS/WinPE reboot) and deserve different wording rather than one
# generic message for both.
$disconnectedSince = $null
$targetBuildKnown = $null
$finalOutcome   = "Timeout"
$finalValidationError = $null
# Phase-stall tracking: NEVER used to declare a failure or stop monitoring -
# only to give EARLY, non-committal visibility if a single phase is taking
# unusually long, so you're not left blind for the full $TimeoutMinutes
# blanket window with zero signal either way. This script never infers a
# failure from elapsed time or a transient probe failure by itself - the
# ONLY things that end monitoring are Server B's own self-reported
# Status=Failed, or the overall -TimeoutMinutes elapsing (which reports a
# neutral "Timeout", not "Failed" - see Section 6). This avoids exactly the
# race condition of declaring an issue before the target has had a fair
# chance to come back up.
$phaseEnteredAt    = Get-Date
$stallWarningCount = 0
# Carried forward across polls whenever a poll has no real PercentComplete
# (e.g. the "WinRMOnly" fallback) - see below for why this must never just
# reset to a hard 0.
$lastKnownPercent  = 0
$lastKnownPercentSource = "Unknown"
# Intelligent "why didn't I see phase X" self-explanation (2026-07-20):
# tracks the last REAL numeric Phase actually read from a genuine status
# source (File/CIM-DCOM - the synthetic WinRMOnly/Heartbeat/Offline
# fallback objects have no Phase number at all, so they never update this).
# Whenever a new real reading jumps by more than 1 (e.g. 3 -> 6, skipping 4
# and 5), this proactively explains WHY in plain language - so the customer
# never has to ask "where did Safe OS/First Boot go" the way you just did;
# the tool now says so itself.
$lastObservedPhaseNum = $null
$phaseFriendlyNames = @{ 1 = "Pre-Upgrade Assessment"; 2 = "Backup"; 3 = "Downlevel Phase"; 4 = "Safe OS Phase"; 5 = "First Boot Phase"; 6 = "Second Boot (OOBE) Phase"; 7 = "Completed" }
# Whether ANY Heartbeat/Offline outage was observed since the last real
# Phase reading - lets the skipped-phase NOTE below distinguish "we know a
# reboot happened, we just couldn't see the individual sub-phases" from the
# more surprising "no outage was ever observed at all, yet phases were still
# skipped" (implies the whole reboot cycle completed faster than even one
# 15-second poll could catch full unreachability).
$outageObservedSinceLastPhase = $false

while ($true) {
    $elapsedMin = (New-TimeSpan -Start $startTime -End (Get-Date)).TotalMinutes
    if ($elapsedMin -gt $TimeoutMinutes) {
        Write-Log "Monitoring timeout ($TimeoutMinutes minutes) reached. Last confirmed phase='$lastConfirmedPhaseName', overall=$lastKnownPercent%. Kindly check $TargetComputer and the target monitor logs. The upgrade outcome is UNVERIFIED; re-running resumes monitoring without launching Setup again." "WARN"
        $timeoutObservation = [pscustomobject]@{
            PingOk = $null; WinRmOk = $null; Mode = "MonitoringStopped"; Source = "ServerA.Timeout"
        }
        Write-LocalStatusMirror -ObservationStatus $timeoutObservation -ObservationError "Monitoring timeout after $TimeoutMinutes minutes."
        $finalOutcome = "Timeout"
        break
    }

    try {
        $status = Get-UpgradeStatus -ComputerName $TargetComputer -Cred $Credential -JsonPath $StatusJsonPath
    } catch {
        # Any unexpected failure here (transient network blip, WMI hiccup, etc.)
        # is treated the same way a WinRM drop is: log it, keep polling, never
        # abort the monitoring loop because of a single failed probe.
        Write-Log "Unexpected error while polling status (non-fatal, will retry): $_" "WARN"
        $errorObservation = [pscustomobject]@{
            PingOk = $null; WinRmOk = $null; Mode = "PollError"; Source = "ServerA.Exception"
        }
        Write-LocalStatusMirror -ObservationStatus $errorObservation -ObservationError $_.Exception.Message
        Start-Sleep -Seconds $PollIntervalSeconds
        continue
    }

    $healthProducer = $script:LastProducerStatus
    if ($null -ne $status.Phase) {
        if (-not $script:ExpectedRunId -and $status.RunId) { $script:ExpectedRunId = $status.RunId }
        $producerKey = "$($status.RunId)|$($status.Sequence)|$($status.StatusUpdatedAtUtc)"
        if ($producerKey -ne $lastProducerKey) {
            $lastProducerAdvanceAtUtc = [DateTimeOffset]::UtcNow
            $lastProducerKey = $producerKey
        }
        $healthProducer = $status
    }
    $healthWarning = Get-UpgradeHealthWarning -Status $status -LastProducer $healthProducer `
        -LastAdvanceAtUtc $lastProducerAdvanceAtUtc -StaleMinutes $StatusStaleWarningMinutes
    $status | Add-Member -NotePropertyName HealthWarning -NotePropertyValue $healthWarning -Force
    $healthKey = if ($status.SetupProcessMissingSinceUtc) { "MissingSetup|$($status.SetupProcessMissingSinceUtc)" }
        elseif ($status.MonitorLastError) { "MonitorError|$($status.MonitorLastError)" }
        elseif ($status.LiveState.MonitorRecoveryError) { $status.LiveState.MonitorRecoveryError }
        else { "Stale|$($healthProducer.Phase)" }
    if ($healthWarning -and ($healthKey -ne $lastHealthWarningKey -or
        ([DateTimeOffset]::UtcNow - $lastHealthWarningAtUtc).TotalMinutes -ge $StatusStaleWarningMinutes)) {
        Write-Log $healthWarning "WARN"
        $lastHealthWarningAtUtc = [DateTimeOffset]::UtcNow
        $lastHealthWarningKey = $healthKey
    } elseif (-not $healthWarning) { $lastHealthWarningKey = "" }
    if ($status.LiveState.MonitorRecovery -and $status.LiveState.MonitorRecovery -ne $lastRecoveryMessage) {
        Write-Log $status.LiveState.MonitorRecovery "WARN"
    }
    $lastRecoveryMessage = $status.LiveState.MonitorRecovery
    if ($null -ne $status.Phase) {
        Write-LocalStatusMirror -ProducerStatus $status -ObservationStatus $status
        foreach ($entry in @(ConvertFrom-UpgradePhaseHistory -History $status.SetupPhaseHistory)) {
            $historyKey = "$($status.RunId)|$($entry.Phase)|$($entry.StartedAtUtc)"
            if (-not $reportedPhaseHistory.ContainsKey($historyKey)) {
                Write-Log "Confirmed Setup history: $($entry.PhaseName) began $($entry.StartedAtUtc) via $($entry.Source). Recovered from the target log; not necessarily observed live."
                $reportedPhaseHistory[$historyKey] = $true
            }
        }
    } else {
        Write-LocalStatusMirror -ObservationStatus $status -ObservationError $status.Notes
    }

    if ($status.TargetBuild) { $targetBuildKnown = $status.TargetBuild }
    # STICKY percentage: only overwrite $lastKnownPercent when THIS poll
    # actually has a real PercentComplete. Some polls (e.g. the "WinRMOnly"
    # fallback, when file-share/DCOM haven't answered yet) legitimately
    # have no number at all - resetting the display to a hard "0%" in that
    # case is actively MISLEADING (it looks like progress was lost/reset,
    # when really we just don't have a fresh reading this cycle). Carrying
    # the last real value forward, tagged "(cached)", is honest about both
    # facts: here's the last progress we actually know, and no, it's not a
    # live reading right this second.
    if ($null -ne $status.PercentComplete) {
        $freshPct = [int]$status.PercentComplete
        # MONOTONIC DISPLAY CLAMP (2026-07-20, real-run bug: a live run
        # showed the bar visibly DROP from 88% to 73% mid-Downlevel while
        # still InProgress - a genuinely fresh, non-null reading that was
        # simply LOWER than a previous one, e.g. a stale SMB/DCOM read
        # racing a concurrent registry write, or the underlying Setup
        # engine's own counter momentarily dipping between internal
        # sub-tasks). Server B's OWN Set-Phase already clamps its registry
        # writes to never decrease while InProgress, but that only protects
        # against Server B regressing itself - it does NOT protect Server A
        # from an occasional stale/racy READ of an OLDER value through a
        # different channel than the one that produced the higher number.
        # A visible regression looks exactly like something went wrong to
        # anyone watching and directly damages confidence in the tool - so
        # Server A now ALSO refuses to ever display a lower number while
        # Status=InProgress, exactly mirroring Server B's own rule (and,
        # like Server B's, deliberately NOT applied to terminal states -
        # Failed/RolledBack correctly showing a real 0% must still get
        # through uncklamped).
        if ($status.Status -eq "InProgress") {
            $freshPct = [math]::Max($freshPct, $lastKnownPercent)
        }
        $lastKnownPercent       = $freshPct
        $lastKnownPercentSource = if ($status.PercentSource) { $status.PercentSource } else { "Unknown" }
        $pctSourceForDisplay    = $lastKnownPercentSource
    } else {
        $pctSourceForDisplay = "$lastKnownPercentSource (cached)"
    }
    $pct = $lastKnownPercent
    # Same sticky principle as $lastKnownPercent above, applied to the
    # PHASE NAME itself: during a connectivity gap, show the last CONFIRMED
    # real phase (tagged as unconfirmed) instead of asserting a specific
    # guessed phase as if it were fact - see $lastConfirmedPhaseName above
    # for why that guess has been directly observed to be wrong.
    $lastConfirmedForDisplay = if ($null -ne $lastConfirmedPhaseName) { $lastConfirmedPhaseName } else { "no phase confirmed yet" }
    $displayPhaseName = if ($null -ne $status.Phase) { $status.PhaseName } else { "$lastConfirmedForDisplay (connectivity gap - phase UNCONFIRMED; could be a Safe OS/WinPE reboot in progress, or just a transient interruption while still in this same phase - next real reading will confirm)" }
    if ($healthWarning) { $displayPhaseName += " | ATTENTION: $healthWarning" }
    $progressFreshnessForDisplay = if ($null -ne $status.Phase -and $status.ProgressFreshness) { $status.ProgressFreshness } else { "CarriedForward" }
    $progressSourceForDisplay = if ($null -ne $status.Phase -and $status.ProgressSource) { $status.ProgressSource } else { "ServerA.CachedProducerStatus" }
    Show-ProgressBar -PercentComplete $pct -PhaseName $displayPhaseName -Status $status.Status `
        -PingOk $status.PingOk -Mode $status.Mode -Source $status.Source -PercentSource $pctSourceForDisplay `
        -ProgressSource $progressSourceForDisplay -ProgressFreshness $progressFreshnessForDisplay -Stage $status.Stage

    # --- Explicit Active-Polling <-> Heartbeat transition logging ------------
    if ($status.Mode -ne $lastMode) {
        switch ($status.Mode) {
            "Heartbeat" {
                if ($lastMode -eq "ActivePolling") {
                    $disconnectedSince = Get-Date
                    $outageObservedSinceLastPhase = $true
                    $probeLevel = if ($null -ne $status.Phase) { "INFO" } else { "WARN" }
                    Write-Log "WinRM probe did not respond on $TargetComputer; continuing through $($status.Source). This is a probe observation, not proof of a reboot or upgrade failure." $probeLevel
                } else {
                    Write-Log "$TargetComputer is reachable (Heartbeat mode via $($status.Source)) - WinRM not yet available."
                }
            }
            "ActivePolling" {
                if ($lastMode -eq "Heartbeat" -or $lastMode -eq "Offline") {
                    # Duration-aware interpretation (2026-07-20, real-run
                    # observation: a 19-SECOND Offline blip was followed by
                    # a generic "resuming Active Polling" message with no
                    # indication of how brief it was - reading it in
                    # isolation made it look like a full Safe OS/WinPE
                    # reboot cycle had just happened, when a real reboot
                    # takes minutes, not seconds, to render ping/WinRM/SMB/
                    # DCOM ALL unreachable and then all reachable again. A
                    # gap this short is almost certainly just a single
                    # flaky poll, not evidence of an actual reboot).
                    $downForText = "an unknown duration"
                    $interpretation = ""
                    if ($disconnectedSince) {
                        $downSecs = [math]::Round(((Get-Date) - $disconnectedSince).TotalSeconds)
                        $downForText = if ($downSecs -lt 60) { "$downSecs sec" } else { "$([math]::Round($downSecs/60,1)) min" }
                        $interpretation = " Outage duration alone does not identify Safe OS, a reboot, or failure. Checking live build, Setup flags, and current-run log evidence."
                    }
                    Write-Log "WinRM probe is responding again on $TargetComputer after $downForText - continuing status monitoring.$interpretation"
                    $disconnectedSince = $null
                    $justReconnected = $true
                } else {
                    Write-Log "$TargetComputer is reachable with WinRM active (Active Polling mode)."
                }
            }
            "Offline" {
                if (-not $disconnectedSince) { $disconnectedSince = Get-Date }
                $outageObservedSinceLastPhase = $true
                Write-Log "$TargetComputer is not responding on ANY channel (ping, WinRM, file-share, or DCOM) - treating as Offline/Rebooting. (If ICMP is blocked in this environment, ping alone would never have been a reliable signal here anyway - this is based on all four channels.)" "WARN"
            }
        }
        $lastMode = $status.Mode
    }

    # Intelligent "why didn't I see phase X" self-explanation. Only real
    # numeric Phase readings (File/CIM-DCOM) update $lastObservedPhaseNum -
    # the synthetic WinRMOnly/Heartbeat/Offline fallbacks never have a Phase
    # number, so a gap naturally accumulates across however many polls it
    # takes to reconnect, and gets explained in one shot the moment a real
    # reading resumes. Only fires for the normal 1-7 sequence (99=RolledBack
    # is a different, already-explained branch, not a "missed phase").
    if ($null -ne $status.Phase) {
        $curPhaseNum = [int]$status.Phase
        if ($null -ne $lastObservedPhaseNum -and $curPhaseNum -gt $lastObservedPhaseNum -and ($curPhaseNum - $lastObservedPhaseNum) -gt 1 -and $curPhaseNum -le 7) {
            $skippedNums  = ($lastObservedPhaseNum + 1)..($curPhaseNum - 1)
            $skippedNames = $skippedNums | ForEach-Object { if ($phaseFriendlyNames.ContainsKey($_)) { $phaseFriendlyNames[$_] } else { "Phase $_" } }
            $outageClause = if ($outageObservedSinceLastPhase) {
                "A connectivity outage WAS observed in between (see the Offline/Heartbeat log lines above), consistent with the reboot(s) these phase(s) require."
            } else {
                "No connectivity outage was sampled; phase execution must be established from Setup logs, not inferred from poll timing."
            }
            Write-Log "NOTE: $($skippedNames -join ' and ') had no live sample between these readings. $outageClause See the confirmed Setup history above when available; missing evidence is not a gap-free timeline or proof of failure." "INFO"
        }
        # Reset unconditionally on every real reading (not just when a skip
        # fires) - otherwise a stale "outage happened" flag from an earlier,
        # already-explained gap could get wrongly attributed to a LATER,
        # unrelated phase transition.
        $outageObservedSinceLastPhase = $false
        $lastObservedPhaseNum = $curPhaseNum
    }

    # --- Phase transition logging - ONLY ever compares/fires on REAL,
    # confirmed Phase readings (never the synthetic Heartbeat/Offline guess
    # text) - see $lastConfirmedPhaseName's own comment above for exactly
    # why: the guess has been directly observed to be wrong (connectivity
    # dropped briefly, guessed "Safe OS", but the real reading afterward
    # showed Server B had never left Downlevel) - comparing against it made
    # an impossible backward phase regression (Safe OS -> Downlevel) appear
    # to happen, when Windows Setup's own model is strictly linear
    # (Downlevel -> Safe OS -> First Boot -> OOBE) and never goes backward.
    if ($null -ne $status.Phase) {
        if ($status.PhaseName -ne $lastConfirmedPhaseName) {
            if ($null -eq $lastConfirmedPhaseName) {
                # The VERY FIRST real reading ever - there's nothing to
                # "change" FROM, so an "'X' -> 'Y'" transition framing would
                # either show a blank/placeholder on the left (confusing -
                # a customer would rightly ask why it's empty) for what
                # isn't really a transition at all. State it plainly instead.
                Write-Log "$(if ($status.Stage) { "[$($status.Stage)] " })First phase detected: '$($status.PhaseName)' (Status=$($status.Status))"
            } else {
                Write-Log "$(if ($status.Stage) { "[$($status.Stage)] " })Phase change detected: '$lastConfirmedPhaseName' -> '$($status.PhaseName)' (Status=$($status.Status))"
            }
            $phaseEnteredAt    = Get-Date
            $stallWarningCount = 0
        } elseif ($justReconnected) {
            # The real phase, once confirmed, turned out to be UNCHANGED
            # from before the connectivity gap - explicitly say so instead
            # of staying silent (silence here would look identical to
            # "nothing happened, still polling normally", when actually a
            # real gap+reconnect cycle just occurred and is worth surfacing).
            Write-Log "$(if ($status.Stage) { "[$($status.Stage)] " })$TargetComputer reconnected. Latest published phase remains '$($status.PhaseName)'; this may be cached until the target monitor refreshes. Live build=$($status.LiveState.CurrentBuild). Absence of a new sample does not prove that Setup stayed in this phase." "INFO"
        } elseif ($status.Status -eq "InProgress") {
            # Escalating, NON-FATAL stall notice - fires at 1x, 2x, 3x... the
            # threshold while still sitting in the SAME phase. Purely
            # informational: monitoring continues exactly as before regardless
            # of how many times this fires. A long Safe OS/First Boot on a
            # slow/large VM is completely normal - this is a "might be worth a
            # look" nudge, never a verdict.
            $minutesInPhase = (New-TimeSpan -Start $phaseEnteredAt -End (Get-Date)).TotalMinutes
            if ($minutesInPhase -gt ($PhaseStallWarningMinutes * ($stallWarningCount + 1))) {
                $stallWarningCount++
                Write-Log "$TargetComputer has been in phase '$($status.PhaseName)' for $([math]::Round($minutesInPhase,1)) min without a phase change (stall notice #$stallWarningCount, threshold $PhaseStallWarningMinutes min). This is informational only - monitoring continues unchanged; large/slow VMs can legitimately take a while here. Worth a manual check on $TargetComputer only if this keeps repeating with no explanation." "WARN"
            }
        }
        $lastConfirmedPhaseName = $status.PhaseName
        $justReconnected = $false
    }

    # --- Failure / rollback: stop monitoring immediately -----------------
    if ($status.Status -eq "Failed") {
        Write-Log "Upgrade reported Status=Failed. Notes: $($status.Notes)" "ERROR"
        $finalOutcome = "Failed"
        break
    }

    # --- Success: require Active Polling (WinRM confirmed back up) + terminal
    # status + live build confirmation. Deliberately gated on Mode=ActivePolling
    # (not just PingOk) so we only declare final success once WinRM has
    # genuinely reconnected post-OOBE, per the requirement that Server A
    # "automatically reconnects and resumes reading the status log" before
    # confirming completion - a Heartbeat-only ping is not sufficient proof
    # the server has finished booting into a fully usable state.
    if ($status.Status -in @("Completed","CompletedWithWarnings")) {
        $remainingMonitorSeconds = [math]::Max(1, [math]::Floor(($TimeoutMinutes * 60) - ((Get-Date) - $startTime).TotalSeconds))
        $validationResult = Wait-UpgradeCompletion -InitialStatus $status -ComputerName $TargetComputer -Cred $Credential `
            -Transport $script:WinRMTransport -TargetBuild $targetBuildKnown `
            -TimeoutSeconds ([int][math]::Min($FinalValidationTimeoutSeconds, $remainingMonitorSeconds))
        $status = $validationResult.Status
        $finalOutcome = $validationResult.Outcome
        $finalValidationError = $validationResult.Error
        break
    }

    # Poll faster while disconnected (Heartbeat/Offline) - see
    # -FastPollIntervalSeconds param comment for why. Back to the normal
    # cadence the moment WinRM/ActivePolling is confirmed up again.
    $sleepSecs = if ($status.Mode -in @("Heartbeat","Offline")) { $FastPollIntervalSeconds } else { $PollIntervalSeconds }
    Start-Sleep -Seconds $sleepSecs
}
Write-Progress -Activity "Monitoring OS upgrade on $TargetComputer" -Completed
$totalMinutes = [math]::Round((New-TimeSpan -Start $startTime -End (Get-Date)).TotalMinutes, 1)

# Pull the extra summary fields off the LAST status snapshot read in the loop
# above ($status stays in scope after while/break) - these are populated by
# Update-UpgradeStatus.ps1's post-upgrade validation (Phase 7) and travel via
# whichever channel (file share / CIM-DCOM) last answered.
$summaryOsCaption      = if ($status.PostUpgradeOSCaption) { $status.PostUpgradeOSCaption } else { "(not reported)" }
$summaryBuild          = if ($status.LiveState.CurrentBuild) { $status.LiveState.CurrentBuild } elseif ($status.VerifiedTargetBuild) { $status.VerifiedTargetBuild } else { "(live build unavailable; expected $targetBuildKnown)" }
$summaryServicesResult = if ($status.ServicesComparisonResult) { $status.ServicesComparisonResult } else { "NotAvailable" }
$summaryServicesPath   = if ($status.ServicesComparisonReportPath) { $status.ServicesComparisonReportPath } else { "(not available)" }
# Customer-facing wording is deliberately calibrated to not cause alarm over
# expected upgrade churn: an in-place OS upgrade routinely changes dozens of
# services (new OS-version services appearing, per-user session services
# re-instantiating under a new suffix, on-demand services simply not
# running at snapshot time) - only services that were genuinely always-on
# (Running+Automatic) and are no longer running/present count toward
# "attention item(s)" (see Update-UpgradeStatus.ps1's classification logic).
$summaryServicesLine = switch ($summaryServicesResult) {
    "Consistent"        { "Consistent - no attention items; $($status.ServicesInfoCount) routine upgrade-related change(s) recorded for reference (report: $summaryServicesPath)" }
    "RequiresAttention"  { "RequiresAttention - $($status.ServicesAttentionCount) item(s) worth a quick review, plus $($status.ServicesInfoCount) expected/benign change(s) not requiring action (full detail: $summaryServicesPath)" }
    "NotAvailable"       { "NotAvailable (no pre-upgrade snapshot found to compare against)" }
    default              { $summaryServicesResult }
}
# Always shown regardless of outcome - licensing/activation is a compliance
# note, not something that should have blocked (or now be silently omitted
# from) an otherwise-successful upgrade.
$summaryLicenseLine = if ($status.LicenseRecommendation) { $status.LicenseRecommendation } else { "Not reported (verify manually: slmgr /dlv)." }
$summaryProfileLine = if ($null -ne $status.UserProfileCount -and $null -ne $status.TotalProfileCount) {
    "$($status.UserProfileCount) user / $($status.TotalProfileCount) total incl. system; inventory=$($status.UserProfileInventoryStatus)"
} else { "Unavailable/not reported; assess profile-related migration duration manually." }

function Write-FinalSummary {
    param([string]$UpgradeStatus)
    Write-Log "===================================================================="
    Write-Log " OS upgrade Status         : $UpgradeStatus"
    Write-Log " Server OS                 : $summaryOsCaption"
    Write-Log " Build                     : $summaryBuild"
    Write-Log " Post-upgrade services     : $summaryServicesLine"
    Write-Log " Licensing/Activation      : $summaryLicenseLine"
    Write-Log " User profiles (precheck)  : $summaryProfileLine"
    Write-Log " Orphan-profile check      : $(if ($status.OrphanedProfileCheckStatus) { $status.OrphanedProfileCheckStatus } else { 'Not reported' })"
    Write-Log " Disk dirty-bit check      : $(if ($status.DirtyBitCheckStatus) { $status.DirtyBitCheckStatus } else { 'Not reported' })"
    Write-Log " Pending-file-rename gate  : $(if ($status.PendingFileRenameCheckStatus) { $status.PendingFileRenameCheckStatus } else { 'Not reported' })"
    Write-Log " Monitoring duration       : $totalMinutes minute(s)."
    Write-Log "===================================================================="
}

switch ($finalOutcome) {
    "Completed" {
        Write-FinalSummary -UpgradeStatus "Success"
        # ARCHITECTURAL NOTE (2026-07-20, customer question: should this
        # wait for/report a distinct "Second Boot completed" step instead
        # of jumping straight to Completed?): deliberately NOT changed.
        # "Completed" fires from Windows Setup's OWN documented /PostOOBE
        # hook - Microsoft's own definition of "the upgrade finished" -
        # plus a local build-number re-verification. Waiting for anything
        # further (e.g. a Group Policy Client refresh screen, or a possible
        # extra reboot) has no natural/deterministic stopping point, since
        # normal Windows machines do background policy/maintenance work on
        # every boot regardless of whether an upgrade just happened -
        # picking a LATER cutoff would make completion detection LESS
        # reliable, not more. Instead: just tell the customer plainly that
        # this is expected, so a still-settling console doesn't look like a
        # contradiction of the "Success" verdict just printed.
        Write-Log "Completion was validated on the target and independently checked through live build/Setup flags. Evidence=$($status.CompletionEvidence). Brief first-logon housekeeping may still follow." "INFO"
        exit 0
    }
    "CompletedWithWarnings" {
        Write-FinalSummary -UpgradeStatus "Success (with warnings - review notes below before closing the change)"
        Write-Log " Notes: $($status.Notes)" "WARN"
        Write-Log "Completion was validated on the target and independently checked through live build/Setup flags. Evidence=$($status.CompletionEvidence). Brief first-logon housekeeping may still follow." "INFO"
        exit 0
    }
    "Failed" {
        Write-FinalSummary -UpgradeStatus "Failed"
        Write-Log " Failed at phase           : $($status.PhaseName) (Notes: $($status.Notes))" "ERROR"
        Write-Log " Review D:\UpgradeBackup\<run>\OSUpgradeProgress.log and Logs\ (incl. SetupDiagResults.xml if present), plus C:\ProgramData\OSUpgradeAutomation\Logs, on $TargetComputer." "ERROR"
        exit 1
    }
    "ValidationFailed" {
        Write-FinalSummary -UpgradeStatus "ERROR - post-upgrade validation unconfirmed"
        Write-Log $finalValidationError "ERROR"
        exit 3
    }
    default {
        Write-Log "Monitoring ended without a terminal status (timeout). Re-run this script to resume monitoring $TargetComputer." "WARN"
        exit 2
    }
}
