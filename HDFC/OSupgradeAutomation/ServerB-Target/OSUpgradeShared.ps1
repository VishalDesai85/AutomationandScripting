<#
.SYNOPSIS
    Shared status-tracking helpers used by BOTH Start-TargetUpgrade.ps1 and
    Update-UpgradeStatus.ps1 on Server B. Dot-sourced, never run directly.

.DESCRIPTION
    Until 2026-09-26 these four functions (Set-UpgradeRegistryValue,
    Get-UpgradeRegistryValue, Write-StatusJson, Set-Phase) were COPY-PASTED
    into both target-side scripts, because the two run as separate processes
    and PowerShell has no implicit sharing between them. That duplication had
    already produced at least two real divergence bugs:

      * the per-stage monotonic percent clamp existed only in
        Update-UpgradeStatus.ps1's copy for a while, so Start-TargetUpgrade.ps1
        logged "Percent=0" moments after backup had genuinely reached 15%;
      * the Write-StatusJson field lists drifted apart, so D:\upgrade_status.json
        contained a different set of keys depending on WHICH script happened to
        write it last.

    Both scripts now dot-source this one file instead, so a fix lands in one
    place and applies everywhere. Nothing here executes at dot-source time -
    it defines functions only.

.NOTES
    CONTRACT - the dot-sourcing script MUST have already set, in its own
    script scope, BEFORE the dot-source statement:
        $script:RegRoot     registry key holding all status values
        $script:StatusJson  full path of the JSON status file to write
    and MUST define its own Write-Log function (the two scripts log to
    different files, and Start-TargetUpgrade.ps1 additionally echoes to the
    console so Server A can stream it live - so Write-Log deliberately stays
    per-script). PowerShell resolves function calls at INVOCATION time, not
    definition time, so Set-Phase below correctly calls whichever Write-Log
    the host script defined.
#>

function Set-UpgradeRegistryValue {
    param([string]$Name, $Value, [string]$Type = "String")
    if (-not (Test-Path $script:RegRoot)) { New-Item -Path $script:RegRoot -Force | Out-Null }
    New-ItemProperty -Path $script:RegRoot -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Get-UpgradeRegistryValue {
    <#
    Read-side counterpart to Set-UpgradeRegistryValue, needed by Set-Phase's
    monotonic-percent clamp and display-fallback logic below.
    #>
    param([string]$Name, $Default = $null)
    if (Test-Path $script:RegRoot) {
        $v = (Get-ItemProperty -Path $script:RegRoot -Name $Name -ErrorAction SilentlyContinue).$Name
        if ($null -ne $v) { return $v }
    }
    return $Default
}

function Get-UpgradeRegistrySnapshot {
    <#
    Reads the ENTIRE status key in ONE registry round-trip and returns it as a
    single object, for callers (Write-StatusJson) that need many fields at
    once. Returns an empty object - never $null - when the key does not exist
    yet, so callers can dot into it unconditionally.
    #>
    $snap = $null
    if (Test-Path $script:RegRoot) {
        $snap = Get-ItemProperty -Path $script:RegRoot -ErrorAction SilentlyContinue
    }
    if ($null -eq $snap) { $snap = [pscustomobject]@{} }
    return $snap
}

function Get-SnapshotValue {
    <#
    Safe field accessor for a Get-UpgradeRegistrySnapshot result. Returns $null
    for a value that isn't present, WITHOUT relying on PowerShell's permissive
    "$null.Property returns $null" behaviour - which Set-StrictMode would turn
    into a terminating PropertyNotFoundException.
    #>
    param($Snapshot, [string]$Name)
    if ($null -eq $Snapshot) { return $null }
    $prop = $Snapshot.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $null
}

function Write-StatusJson {
    <#
    Writes the full status object to $script:StatusJson (D:\upgrade_status.json
    by default). This is the primary channel Server A reads directly (over the
    admin share) when WinRM is unavailable during Downlevel/SafeOS transitions.
    Wrapped defensively - a transient file lock must never abort the upgrade.

    PERF/CORRECTNESS (2026-09-26): this used to issue ONE Get-ItemProperty call
    PER FIELD - up to 23 separate registry round-trips per call, and Set-Phase
    calls it on every single pre-check and backup task (22+ times per run, so
    500+ reads). It now takes a single snapshot of the whole key. Besides the
    ~95% cut in registry I/O this also makes the JSON internally CONSISTENT:
    previously the per-field reads could interleave with a concurrent write
    from the other script/process, producing a file where e.g. Phase came from
    before the write and PercentComplete from after it.

    RETURNS $true if the file was published, $false if it could not be. This
    is load-bearing, not informational: Update-UpgradeStatus.ps1 only tears
    down the monitor scheduled tasks once a TERMINAL status has actually
    reached the JSON file - unregistering them after a failed write would
    strand Server A with no way to ever learn the run finished. Callers must
    therefore ASSIGN the result rather than calling this bare, or the boolean
    leaks into Set-Phase's output stream and prints "True" on the console.
    #>
    param([hashtable]$Extra = @{})
    try {
        $reg = Get-UpgradeRegistrySnapshot
        # Field list is the UNION of what the two scripts used to write
        # separately - Server A tolerates null-valued keys fine (it already
        # reads every one of these as "may be absent"), whereas a key that
        # disappears entirely depending on which process wrote last is what
        # actually caused confusion before.
        $obj = [ordered]@{
            ComputerName                 = $env:COMPUTERNAME
            Phase                        = Get-SnapshotValue $reg "Phase"
            PhaseName                    = Get-SnapshotValue $reg "PhaseName"
            Status                       = Get-SnapshotValue $reg "Status"
            PercentComplete              = Get-SnapshotValue $reg "PercentComplete"
            PercentSource                = Get-SnapshotValue $reg "PercentSource"
            ProgressFreshness            = Get-SnapshotValue $reg "ProgressFreshness"
            ProgressUpdatedAtUtc         = Get-SnapshotValue $reg "ProgressUpdatedAtUtc"
            ProgressHighWaterPercent     = Get-SnapshotValue $reg "ProgressHighWaterPercent"
            ProgressHighWaterStage       = Get-SnapshotValue $reg "ProgressHighWaterStage"
            StatusUpdatedAtUtc           = Get-SnapshotValue $reg "StatusUpdatedAtUtc"
            ExpectedDisconnect           = Get-SnapshotValue $reg "ExpectedDisconnect"
            SourceBuild                  = Get-SnapshotValue $reg "SourceBuild"
            TargetBuild                  = Get-SnapshotValue $reg "TargetBuild"
            TargetOSCaption              = Get-SnapshotValue $reg "TargetOSCaption"
            Stage                        = Get-SnapshotValue $reg "Stage"
            StartTime                    = Get-SnapshotValue $reg "StartTime"
            LastUpdated                  = Get-SnapshotValue $reg "LastUpdated"
            Notes                        = Get-SnapshotValue $reg "Notes"
            SetupLogTail                 = Get-SnapshotValue $reg "SetupLogTail"
            PostUpgradeOSCaption         = Get-SnapshotValue $reg "PostUpgradeOSCaption"
            PostUpgradeBuild             = Get-SnapshotValue $reg "PostUpgradeBuild"
            PostUpgradeValidationTime    = Get-SnapshotValue $reg "PostUpgradeValidationTime"
            PostUpgradeValidationResult  = Get-SnapshotValue $reg "PostUpgradeValidationResult"
            ServicesComparisonResult     = Get-SnapshotValue $reg "ServicesComparisonResult"
            ServicesComparisonReportPath = Get-SnapshotValue $reg "ServicesComparisonReportPath"
            ServicesAttentionCount       = Get-SnapshotValue $reg "ServicesAttentionCount"
            ServicesInfoCount            = Get-SnapshotValue $reg "ServicesInfoCount"
            LicenseRecommendation        = Get-SnapshotValue $reg "LicenseRecommendation"
        }
        foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] }
        # Atomic-ish write: build the complete file under a .tmp name and then
        # Move-Item over the real one, so Server A's SMB reader can never
        # observe a half-written JSON document.
        $tmp = "$($script:StatusJson).tmp"
        ($obj | ConvertTo-Json -Depth 4) | Out-File -FilePath $tmp -Encoding UTF8 -Force
        Move-Item -Path $tmp -Destination $script:StatusJson -Force
        return $true
    } catch {
        Write-Log "Non-blocking: failed to write status JSON to $script:StatusJson : $_" "WARN"
        return $false
    }
}

function Set-Phase {
    <# Single source of truth for phase/status - updates registry AND JSON together. #>
    param(
        [int]$Phase, [string]$PhaseName,
        [string]$Status = "InProgress",
        [int]$PercentComplete = -1,
        [string]$Notes = "",
        # "Measured" = derived from a real, live data source (a task count we
        # genuinely own, or Windows Setup's documented MoSetup value);
        # "Estimated" (default) = a best-effort milestone marker where no live
        # telemetry source exists (Safe OS/WinPE blind window, or the one-shot
        # OOBE hook). Callers pass "Measured" explicitly ONLY where a real
        # value was actually obtained.
        [ValidateSet("Measured","Estimated")][string]$PercentSource = "Estimated",
        [ValidateSet("Live","Milestone")][string]$ProgressFreshness = "Live"
    )
    # ---- Monotonicity / truthfulness guards -------------------------------
    # These matter because Set-Phase is reached from FOUR uncoordinated
    # triggers on the target: the 2-minute OSUpgradePhaseMonitor task, the
    # Event-ID-1074 reboot watcher, setupcomplete.cmd and setuprollback.cmd.
    # Two of them firing seconds apart used to be able to publish an ordering
    # that never actually happened.
    $storedStatus = Get-UpgradeRegistryValue -Name "Status"
    $storedPhase  = [int](Get-UpgradeRegistryValue -Name "Phase" -Default 0)
    # 1. A terminal status is FINAL. The single exception is a rollback
    #    (Phase 99) arriving after something else already declared failure -
    #    that carries strictly more information, so it is allowed through.
    if ($storedStatus -in @("Completed", "CompletedWithWarnings", "Failed") -and
        -not ($Status -eq "Failed" -and $Phase -eq 99)) {
        # Leave the terminal REGISTRY state exactly as it is - but do retry
        # the JSON publication before returning. Update-UpgradeStatus.ps1
        # deliberately keeps the 2-minute monitor task alive when a terminal
        # status reached the registry but the JSON write failed (disk full,
        # D: transiently unavailable), so that the next poll can republish.
        # Without this line that retry could never succeed: the second poll
        # would hit this guard, return with $script:StatusJsonPublished still
        # $false, and the task would poll forever having given up on the one
        # channel Server A was waiting on.
        $script:StatusJsonPublished = Write-StatusJson
        return
    }
    # 2. Never claim success without local evidence. Completion is the one
    #    status Server A reports to the customer as "done", and a stray hook
    #    firing at the wrong moment must not be able to manufacture it -
    #    Invoke-PostUpgradeValidation has to have actually run and confirmed
    #    the running build matches the target build first.
    if ($Status -in @("Completed", "CompletedWithWarnings")) {
        $expectedBuild    = Get-UpgradeRegistryValue -Name "TargetBuild"
        $validatedBuild   = Get-UpgradeRegistryValue -Name "PostUpgradeBuild"
        $validationResult = Get-UpgradeRegistryValue -Name "PostUpgradeValidationResult"
        $validationTime   = Get-UpgradeRegistryValue -Name "PostUpgradeValidationTime"
        if (-not $expectedBuild -or $validatedBuild -ne $expectedBuild -or
            $validationResult -notin @("Passed", "PassedWithWarnings") -or -not $validationTime) {
            throw "Cannot publish successful completion without target-build and post-validation evidence."
        }
    }
    # 3. Phases only move forwards while a run is in progress. (Terminal
    #    statuses are exempt: Phase 99 "Rolled Back" is deliberately numbered
    #    high precisely so it can never be mistaken for backwards movement,
    #    and a Failed at any phase must always be publishable.)
    #    NOTE for Start-TargetUpgrade.ps1: this is a no-op there - it only
    #    ever walks 1 -> 2 -> 3, and Section 0 wipes $script:RegRoot (or hard-
    #    throws) before its first Set-Phase call, so no prior run's stored
    #    phase or terminal status is ever visible to guard 1 or 3 above.
    if ($Status -eq "InProgress" -and $Phase -lt $storedPhase) { return }
    # -----------------------------------------------------------------------
    # Stage grouping for customer-facing display: Stage 1/2 are OUR OWN
    # script's work (prechecks/backup); Stage 3 is Windows Setup's own engine
    # actually running (Downlevel through Completed/RolledBack) - this
    # distinction is what the customer asked to see called out clearly.
    $stageLabel = switch ($Phase) {
        1       { "Stage 1/3: Pre-Upgrade Assessment" }
        2       { "Stage 2/3: Backup" }
        99      { "Stage 3/3: Windows Setup Execution (Rolled Back)" }
        default { "Stage 3/3: Windows Setup Execution" }
    }
    $progressStage = if ($Phase -eq 99) { "Stage 3/3: Windows Setup Execution" } else { $stageLabel }
    $statusUpdatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    Set-UpgradeRegistryValue -Name "Stage"       -Value $stageLabel
    Set-UpgradeRegistryValue -Name "Phase"       -Value $Phase -Type DWord
    Set-UpgradeRegistryValue -Name "PhaseName"   -Value $PhaseName
    Set-UpgradeRegistryValue -Name "LastUpdated" -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Set-UpgradeRegistryValue -Name "StatusUpdatedAtUtc" -Value $statusUpdatedAtUtc
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
        # SCOPED TO STAGE, NOT GLOBAL (2026-07-24): each Stage has its OWN
        # independent 0-100 percentage (Stage 1/2 = task-count-based, Stage 3
        # = setup.exe telemetry) - clamping against whatever the PREVIOUS
        # stage ended at would wrongly force a new stage's fresh,
        # genuinely-lower starting percent (e.g. Stage 3 Downlevel's real
        # first Measured reading of 15%) up to the prior stage's ending value
        # (e.g. Stage 2 finishing at 100%). Only clamp when the stored percent
        # came from THIS SAME stage - never carry a high-water mark across a
        # stage boundary, only within one.
        $priorPercentValue = Get-UpgradeRegistryValue -Name "PercentComplete"
        $priorPercentStage = Get-UpgradeRegistryValue -Name "PercentStage"
        $retainedTerminalProgress = $false
        if ($Status -eq "Failed" -and $null -ne $priorPercentValue -and
            ($priorPercentStage -eq $stageLabel -or ($Phase -eq 99 -and $storedPhase -ge 3))) {
            $PercentComplete = [math]::Max($PercentComplete, [int]$priorPercentValue)
            $retainedTerminalProgress = $true
        } elseif ($Status -eq "InProgress" -and $priorPercentStage -eq $stageLabel) {
            $priorPercent = [int]$priorPercentValue
            $PercentComplete = [math]::Max($PercentComplete, $priorPercent)
        }
        Set-UpgradeRegistryValue -Name "PercentComplete" -Value $PercentComplete -Type DWord
        Set-UpgradeRegistryValue -Name "PercentSource"   -Value $PercentSource
        Set-UpgradeRegistryValue -Name "PercentStage"    -Value $stageLabel
        $priorHighWater = if ((Get-UpgradeRegistryValue -Name "ProgressHighWaterStage") -eq $progressStage) {
            [int](Get-UpgradeRegistryValue -Name "ProgressHighWaterPercent" -Default 0)
        } else { 0 }
        Set-UpgradeRegistryValue -Name "ProgressHighWaterPercent" -Value ([math]::Max($PercentComplete, $priorHighWater)) -Type DWord
        Set-UpgradeRegistryValue -Name "ProgressHighWaterStage" -Value $progressStage
        Set-UpgradeRegistryValue -Name "ProgressFreshness" -Value $(if ($Status -in @("Completed", "CompletedWithWarnings", "Failed")) { "Terminal" } else { $ProgressFreshness })
        if (-not $retainedTerminalProgress) {
            Set-UpgradeRegistryValue -Name "ProgressUpdatedAtUtc" -Value $statusUpdatedAtUtc
        }
    } elseif ((Get-UpgradeRegistryValue -Name "PercentStage") -and (Get-UpgradeRegistryValue -Name "PercentStage") -ne $stageLabel) {
        # BUG FIX (2026-08-26, real TestVM2 run): entering a NEW stage with no
        # fresh measurement yet used to leave the PREVIOUS stage's ending
        # PercentComplete/PercentSource sitting untouched in the registry -
        # already correctly hidden from the console log below via the
        # $displayPct stage-match check, but Write-StatusJson and the
        # orchestrator's CIM/DCOM registry read both consume the RAW registry
        # values directly, so they kept showing e.g. "100% Measured" (Stage
        # 2's ending backup percent) mislabeled under the brand-new Stage
        # 3/Downlevel Phase - looking like Setup was already done when it had
        # barely started. Clear the stale values here so every channel
        # (console, JSON, CIM/DCOM) agrees there is no measurement yet for
        # this stage.
        Remove-ItemProperty -Path $script:RegRoot -Name "PercentComplete" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $script:RegRoot -Name "PercentSource" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $script:RegRoot -Name "ProgressFreshness" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $script:RegRoot -Name "ProgressUpdatedAtUtc" -ErrorAction SilentlyContinue
        Set-UpgradeRegistryValue -Name "PercentStage" -Value $stageLabel
    } elseif ($null -ne (Get-UpgradeRegistryValue -Name "PercentComplete")) {
        Set-UpgradeRegistryValue -Name "ProgressFreshness" -Value $(if ($Status -in @("Completed", "CompletedWithWarnings", "Failed")) { "Terminal" } else { "CarriedForward" })
    }
    if ($Notes) { Set-UpgradeRegistryValue -Name "Notes" -Value $Notes }
    if ($Status -in @("Completed", "CompletedWithWarnings", "Failed")) {
        Set-UpgradeRegistryValue -Name "ExpectedDisconnect" -Value 0 -Type DWord
    }
    # Publish the terminal indicator only AFTER its supporting fields. Server
    # A's CIM/DCOM channel reads these values one at a time, so writing Status
    # first would let it observe "Completed" alongside the previous phase's
    # stale PercentComplete/Notes for the duration of the writes below.
    Set-UpgradeRegistryValue -Name "Status" -Value $Status
    # Callers can omit -PercentComplete entirely (leaving it at the -1 default)
    # for phases where NO real measurement exists (Safe OS/WinPE, the OOBE
    # hook, or a "no telemetry yet" fallback) instead of writing a fabricated
    # "Estimated" milestone number - customer feedback was that seeing an
    # invented placeholder percentage looked like real regressed/reset
    # progress. When omitted, resolve what to DISPLAY (log text only - the
    # registry itself is simply left untouched above) from whatever the last
    # REAL value already in the registry was, so the log/JSON/GUI keep showing
    # the last genuine reading instead of a fake number or a "-1".
    # BUG FIX (2026-07-20): the fallback below used to default to a hardcoded
    # 0/"Estimated" when nothing was stored yet - which, on Phase 1's very
    # first call ever (fresh registry, nothing to carry forward),
    # reconstructed the exact same "Percent=0 (Estimated)" text the whole
    # point of omitting -PercentComplete was meant to eliminate. Now
    # distinguishes "no real value EVER existed" ($null - show nothing) from
    # "a real value exists to carry forward" (show it).
    $storedPct    = Get-UpgradeRegistryValue -Name "PercentComplete"
    $storedSource = Get-UpgradeRegistryValue -Name "PercentSource"
    $storedStage  = Get-UpgradeRegistryValue -Name "PercentStage"
    if ($PercentComplete -ge 0) {
        $displayPct    = $PercentComplete
        $displaySource = $PercentSource
    } elseif ($null -ne $storedPct -and $storedStage -eq $stageLabel) {
        # Only carry forward a stored value that belongs to THIS SAME stage
        # (2026-07-24) - otherwise a fresh stage's very first no-percent call
        # (e.g. Phase 2's kickoff) would momentarily flash the PRIOR stage's
        # ending percent (e.g. Stage 1 finishing at 100%) before its own first
        # real percent overwrites it a moment later. Within Stage 3 itself
        # (Phases 3-7/99 all share the same stageLabel) this is a no-op -
        # carry-forward across those phases continues exactly as before.
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
    # MUST be assigned, not called bare - Write-StatusJson returns a boolean.
    # Update-UpgradeStatus.ps1 reads $script:StatusJsonPublished to decide
    # whether it is safe to unregister the monitor tasks; Start-TargetUpgrade
    # .ps1 ignores it, but the assignment still keeps "True" off its console.
    $script:StatusJsonPublished = Write-StatusJson

    # Mirror the same phase/percent line into a second, durable copy inside
    # the change's own D:\UpgradeBackup\<run> folder - unlike
    # C:\ProgramData\OSUpgradeAutomation\Logs (purged by
    # Remove-UpgradeArtifacts.ps1 after -RetentionDays), that backup folder is
    # intentionally never auto-deleted, so this becomes the durable end-to-end
    # record of exactly how long each phase took, from Downlevel through
    # Completed/Rolled Back - or exactly which phase it failed at.
    # NOTE (2026-09-26): now that both scripts share this function, Stage 2's
    # backup task progress gets mirrored here too, not just Stage 3's - the
    # BackupFolder registry value simply doesn't exist yet during Stage 1, so
    # the Test-Path below skips silently exactly as before.
    try {
        $backupFolder = Get-UpgradeRegistryValue -Name "BackupFolder"
        if ($backupFolder -and (Test-Path $backupFolder)) {
            $progressLine = "[{0}] [{1}] Phase={2} ({3}) Status={4}{5} {6}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $stageLabel, $Phase, $PhaseName, $Status, $pctClause, $Notes
            Add-Content -Path (Join-Path $backupFolder "OSUpgradeProgress.log") -Value $progressLine -Encoding UTF8
        }
    } catch {
        Write-Log "Non-blocking: failed to mirror progress line to the backup folder: $_" "WARN"
    }
}
