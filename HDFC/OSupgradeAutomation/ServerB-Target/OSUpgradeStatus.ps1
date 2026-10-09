<#
.SYNOPSIS
    Shared status/progress contract for the target-side OS upgrade scripts.

.DESCRIPTION
    PercentComplete is the monotonic, end-to-end percentage consumed by
    external systems. StagePercentComplete retains the local 0-100 progress
    for the current stage. The fixed workflow ranges are:

      Stage 1 - Prechecks             0-10
      Stage 2 - Backup               10-25
      Stage 3 - Downlevel            25-50
                Safe OS             50-70
                First Boot          70-85
                Second Boot         85-95
      Post-upgrade validation        95-100

    These values measure workflow completion, not elapsed-time prediction.
    Both target-side PowerShell processes dot-source this file so registry and
    JSON semantics cannot drift apart.
#>

function Set-UpgradeRegistryValue {
    param([string]$Name, $Value, [string]$Type = "String")
    if (-not (Test-Path $script:RegRoot)) { New-Item -Path $script:RegRoot -Force | Out-Null }
    New-ItemProperty -Path $script:RegRoot -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Get-UpgradeRegistryValue {
    param([string]$Name, $Default = $null)
    if (Test-Path $script:RegRoot) {
        $value = (Get-ItemProperty -Path $script:RegRoot -Name $Name -ErrorAction SilentlyContinue).$Name
        if ($null -ne $value) { return $value }
    }
    return $Default
}

function ConvertFrom-UpgradePhaseHistory {
    param([object]$History)
    if ($History -is [string]) {
        if ([string]::IsNullOrWhiteSpace($History)) { return }
        $History = ConvertFrom-Json -InputObject $History -ErrorAction Stop
    }
    foreach ($entry in $History) {
        if ($entry -is [System.Collections.IList]) {
            ConvertFrom-UpgradePhaseHistory -History $entry
        } elseif ($null -ne $entry) {
            $stamp = [DateTimeOffset]::MinValue
            if ($entry.Phase -notin @(3,4,5,6) -or -not $entry.PhaseName -or -not $entry.Source -or
                -not [DateTimeOffset]::TryParse([string]$entry.StartedAtUtc, [ref]$stamp)) {
                Write-Log "Ignoring an invalid Setup phase-history entry; it is not execution evidence." "WARN"
                continue
            }
            $entry
        }
    }
}

function Write-UpgradeJsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Json)
    $temporaryPath = "{0}.{1}.{2}.tmp" -f $Path, $PID, ([guid]::NewGuid().ToString("N"))
    try {
        $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($temporaryPath, $Json, $utf8WithoutBom)
        for ($attempt = 0; $attempt -lt 4; $attempt++) {
            try {
                if ([System.IO.File]::Exists($Path)) {
                    [System.IO.File]::Replace($temporaryPath, $Path, [NullString]::Value, $true)
                } else {
                    [System.IO.File]::Move($temporaryPath, $Path)
                }
                return
            } catch [System.IO.IOException] {
                if ($attempt -eq 3) { throw }
                # A concurrent reader may briefly deny replacement, or another writer
                # may have created the destination after the existence check.
                Start-Sleep -Milliseconds 100
            }
        }
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }
    }
}

function Get-UpgradePendingRebootState {
    param([switch]$SkipPendingFileRenameCheck)

    $reasons = @()
    $blockingReasons = @()
    $operations = @()
    $cbsPending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -ErrorAction Stop
    $updatePending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -ErrorAction Stop
    if ($cbsPending) { $reasons += 'CBS RebootPending key present' }
    if ($updatePending) { $reasons += 'Windows Update RebootRequired key present' }
    $blockingReasons += $reasons
    $sessionManager = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction Stop
    $entries = @($sessionManager.PendingFileRenameOperations)
    for ($entryIndex = 0; $entryIndex -lt $entries.Count; $entryIndex += 2) {
        $source = [string]$entries[$entryIndex]
        $destination = if ($entryIndex + 1 -lt $entries.Count) { [string]$entries[$entryIndex + 1] } else { '' }
        if ([string]::IsNullOrWhiteSpace($source) -and [string]::IsNullOrWhiteSpace($destination)) { continue }
        $operation = [pscustomobject]@{
            Source = $source
            Destination = $destination
            Action = $(if (-not $source) { 'InvalidEntry' } elseif ($destination) { 'RenameOrReplace' } else { 'Delete' })
        }
        $operations += $operation
        $reason = "PendingFileRenameOperations: $($operation.Action) '$source' -> '$destination'"
        $reasons += $reason
        if (-not $SkipPendingFileRenameCheck) { $blockingReasons += $reason }
    }
    [pscustomobject]@{
        RebootPending = ($reasons.Count -gt 0)
        UpgradeBlocked = ($blockingReasons.Count -gt 0)
        CBSRebootPending = $cbsPending
        WindowsUpdateRebootRequired = $updatePending
        PendingFileRenameOperationsPresent = ($operations.Count -gt 0)
        PendingFileRenameCheckSkipped = [bool]$SkipPendingFileRenameCheck
        Operations = $operations
        Reasons = $reasons
        BlockingReasons = $blockingReasons
    }
}

function Get-UpgradeDiskDirtyState {
    $volumes = @(Get-CimInstance -ClassName Win32_Volume -Filter "DriveType=3 AND FileSystem='NTFS'" -ErrorAction Stop)
    if (-not ($volumes | Where-Object { $_.DriveLetter -eq $env:SystemDrive })) {
        throw "Could not enumerate the system NTFS volume $env:SystemDrive for dirty-bit validation."
    }
    foreach ($volume in $volumes) {
        $volumePath = if ($volume.DriveLetter) { $volume.DriveLetter } else { $volume.DeviceID }
        if (-not $volumePath) { throw "An NTFS volume has neither a drive letter nor a volume GUID." }
        $output = (& fsutil.exe dirty query $volumePath 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "fsutil dirty query $volumePath failed (exit $LASTEXITCODE): $output" }

        # fsutil's text is localized; CIM supplies the same bit on non-English hosts.
        if ($output -match '(?im)^\s*Volume .+ is (?<clean>not )?dirty\s*\.?\s*$') {
            $isDirty = -not [bool]$Matches['clean']
        } elseif ($null -ne $volume.DirtyBitSet) {
            $isDirty = [bool]$volume.DirtyBitSet
        } else {
            throw "Cannot interpret the dirty-bit result for ${volumePath}: $output"
        }
        [pscustomobject]@{ Volume = $volumePath; IsDirty = $isDirty; Output = $output }
    }
}

function Get-UpgradeUserProfileInventory {
    $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop |
        Select-Object SID, LocalPath, Special, Loaded, LastUseTime)
    if (@($profiles | Where-Object { -not $_.SID -or $null -eq $_.Special }).Count) {
        throw "Win32_UserProfile returned incomplete SID/Special metadata; the profile count cannot be verified."
    }
    $users = @($profiles | Where-Object { -not $_.Special })
    [pscustomobject]@{
        UserProfileCount = $users.Count
        SpecialProfileCount = @($profiles | Where-Object { $_.Special }).Count
        TotalProfileCount = $profiles.Count
        LoadedUserProfileCount = @($users | Where-Object { $_.Loaded }).Count
        Profiles = $profiles
    }
}

function Get-UpgradeStageMetadata {
    param([int]$Phase)

    switch ($Phase) {
        1 {
            [pscustomobject]@{ Number = 1; Name = "Stage 1/3: Pre-Upgrade Assessment"; Start = 0; End = 10 }
        }
        2 {
            [pscustomobject]@{ Number = 2; Name = "Stage 2/3: Backup"; Start = 10; End = 25 }
        }
        99 {
            [pscustomobject]@{ Number = 3; Name = "Stage 3/3: Windows Setup Execution (Rolled Back)"; Start = 25; End = 95 }
        }
        default {
            [pscustomobject]@{ Number = 3; Name = "Stage 3/3: Windows Setup Execution"; Start = 25; End = 95 }
        }
    }
}

function ConvertTo-OverallUpgradePercent {
    param(
        [int]$Phase,
        [int]$StageNumber,
        [int]$StagePercentComplete,
        [string]$Status = "InProgress"
    )

    if ($Phase -eq 7 -and $Status -in @("Completed", "CompletedWithWarnings")) { return 100 }

    $boundedStagePercent = [math]::Max(0, [math]::Min(100, $StagePercentComplete))
    $range = switch ($Phase) {
        1 { [pscustomobject]@{ Start = 0; End = 10 } }
        2 { [pscustomobject]@{ Start = 10; End = 25 } }
        3 { [pscustomobject]@{ Start = 25; End = 50 } }
        4 { [pscustomobject]@{ Start = 50; End = 70 } }
        5 { [pscustomobject]@{ Start = 70; End = 85 } }
        6 { [pscustomobject]@{ Start = 85; End = 95 } }
        7 { [pscustomobject]@{ Start = 95; End = 99 } }
        default { [pscustomobject]@{ Start = 25; End = 95 } }
    }
    return [int][math]::Floor($range.Start + (($range.End - $range.Start) * ($boundedStagePercent / 100.0)))
}

function Get-UpgradeStatusSnapshot {
    # Set-Phase owns the writer lock. Readers must not open a mutex created
    # under SYSTEM's default ACL; remoting administrators may lack access.
    $registry = Get-ItemProperty -Path $script:RegRoot -ErrorAction Stop
    function Get-SnapshotValue {
        param([string]$Name)
        if (-not $registry) { return $null }
        $property = $registry.PSObject.Properties[$Name]
        if ($property) { return $property.Value }
        return $null
    }

    $status = Get-SnapshotValue -Name "Status"
    [ordered]@{
        SchemaVersion                = Get-SnapshotValue -Name "SchemaVersion"
        RunId                        = Get-SnapshotValue -Name "RunId"
        Sequence                     = Get-SnapshotValue -Name "Sequence"
        ComputerName                 = $env:COMPUTERNAME
        Status                       = $status
        IsTerminal                   = ($status -in @("Completed", "CompletedWithWarnings", "Failed"))
        Phase                        = Get-SnapshotValue -Name "Phase"
        PhaseName                    = Get-SnapshotValue -Name "PhaseName"
        StageNumber                  = Get-SnapshotValue -Name "StageNumber"
        Stage                        = Get-SnapshotValue -Name "Stage"
        StagePercentComplete         = Get-SnapshotValue -Name "StagePercentComplete"
        PhasePercentComplete         = Get-SnapshotValue -Name "PhasePercentComplete"
        OverallPercentComplete       = Get-SnapshotValue -Name "OverallPercentComplete"
        PercentComplete              = Get-SnapshotValue -Name "PercentComplete"
        PercentSource                = Get-SnapshotValue -Name "PercentSource"
        ProgressSource               = Get-SnapshotValue -Name "ProgressSource"
        ProgressFreshness            = Get-SnapshotValue -Name "ProgressFreshness"
        ProgressUpdatedAtUtc         = Get-SnapshotValue -Name "ProgressUpdatedAtUtc"
        StatusUpdatedAtUtc           = Get-SnapshotValue -Name "StatusUpdatedAtUtc"
        LastUpdated                  = Get-SnapshotValue -Name "LastUpdated"
        StartTime                    = Get-SnapshotValue -Name "StartTime"
        StartTimeUtc                 = Get-SnapshotValue -Name "StartTimeUtc"
        SetupLaunchTimeUtc           = Get-SnapshotValue -Name "SetupLaunchTimeUtc"
        ExpectedDisconnect           = [bool](Get-SnapshotValue -Name "ExpectedDisconnect")
        RebootCount                  = Get-SnapshotValue -Name "RebootCount"
        LastObservedBootTimeUtc      = Get-SnapshotValue -Name "LastObservedBootTimeUtc"
        BootEvidence                 = Get-SnapshotValue -Name "BootEvidence"
        RestartRequestedAtUtc        = Get-SnapshotValue -Name "RestartRequestedAtUtc"
        UnexpectedRestartAtUtc       = Get-SnapshotValue -Name "UnexpectedRestartAtUtc"
        SetupPhaseHistory            = @(ConvertFrom-UpgradePhaseHistory -History (Get-SnapshotValue -Name "SetupPhaseHistory"))
        SourceBuild                  = Get-SnapshotValue -Name "SourceBuild"
        TargetBuild                  = Get-SnapshotValue -Name "TargetBuild"
        SourceOSCaption              = Get-SnapshotValue -Name "SourceOSCaption"
        TargetOSCaption              = Get-SnapshotValue -Name "TargetOSCaption"
        PostUpgradeOSCaption         = Get-SnapshotValue -Name "PostUpgradeOSCaption"
        Notes                        = Get-SnapshotValue -Name "Notes"
        SetupLogTail                 = Get-SnapshotValue -Name "SetupLogTail"
        SetupTelemetryPercent        = Get-SnapshotValue -Name "SetupTelemetryPercent"
        SetupTelemetryPhase          = Get-SnapshotValue -Name "SetupTelemetryPhase"
        SetupTelemetrySource         = Get-SnapshotValue -Name "SetupTelemetrySource"
        SetupProcessMissingSinceUtc  = Get-SnapshotValue -Name "SetupProcessMissingSinceUtc"
        SetupFailureDetectedAtUtc    = Get-SnapshotValue -Name "SetupFailureDetectedAtUtc"
        MonitorLastError             = Get-SnapshotValue -Name "MonitorLastError"
        VerifiedTargetBuild          = Get-SnapshotValue -Name "VerifiedTargetBuild"
        CompletionEvidence           = Get-SnapshotValue -Name "CompletionEvidence"
        ServicesComparisonResult     = Get-SnapshotValue -Name "ServicesComparisonResult"
        ServicesComparisonReportPath = Get-SnapshotValue -Name "ServicesComparisonReportPath"
        ServicesAttentionCount       = Get-SnapshotValue -Name "ServicesAttentionCount"
        ServicesInfoCount            = Get-SnapshotValue -Name "ServicesInfoCount"
        LicenseRecommendation        = Get-SnapshotValue -Name "LicenseRecommendation"
        BackupFolder                 = Get-SnapshotValue -Name "BackupFolder"
        SystemStateBackupPath        = Get-SnapshotValue -Name "SystemStateBackupPath"
        DirtyBitCheckStatus          = Get-SnapshotValue -Name "DirtyBitCheckStatus"
        UserProfileInventoryStatus   = Get-SnapshotValue -Name "UserProfileInventoryStatus"
        UserProfileCount             = Get-SnapshotValue -Name "UserProfileCount"
        SpecialProfileCount          = Get-SnapshotValue -Name "SpecialProfileCount"
        TotalProfileCount            = Get-SnapshotValue -Name "TotalProfileCount"
        LoadedUserProfileCount       = Get-SnapshotValue -Name "LoadedUserProfileCount"
        UserProfileInventoryPath     = Get-SnapshotValue -Name "UserProfileInventoryPath"
        OrphanedProfileCheckStatus   = Get-SnapshotValue -Name "OrphanedProfileCheckStatus"
        OrphanedProfileCount         = Get-SnapshotValue -Name "OrphanedProfileCount"
        PendingFileRenameCheckStatus = Get-SnapshotValue -Name "PendingFileRenameCheckStatus"
    }
}

function Write-StatusJson {
    param([hashtable]$Extra = @{})

    try {
        $statusObject = Get-UpgradeStatusSnapshot
        foreach ($name in $Extra.Keys) { $statusObject[$name] = $Extra[$name] }

        $statusDirectory = Split-Path -Parent $script:StatusJson
        if ($statusDirectory -and -not (Test-Path $statusDirectory)) {
            New-Item -ItemType Directory -Path $statusDirectory -Force | Out-Null
        }

        $json = $statusObject | ConvertTo-Json -Depth 6
        Write-UpgradeJsonFile -Path $script:StatusJson -Json $json

        $backupFolder = Get-UpgradeRegistryValue -Name "BackupFolder"
        if ($backupFolder -and (Test-Path $backupFolder)) {
            ($statusObject | ConvertTo-Json -Depth 6 -Compress) |
                Add-Content -Path (Join-Path $backupFolder "OSUpgradeStatusHistory.jsonl") -Encoding UTF8
        }
    } catch {
        Write-Log "Non-blocking: failed to write status JSON to $script:StatusJson : $_" "WARN"
    }
}

function Set-Phase {
    param(
        [int]$Phase,
        [string]$PhaseName,
        [string]$Status = "InProgress",
        [Alias("StagePercentComplete", "PhasePercentComplete")][int]$PercentComplete = -1,
        [string]$Notes = "",
        [ValidateSet("Measured", "Estimated")][string]$PercentSource = "Measured",
        [string]$ProgressSource = "",
        [ValidateSet("Live", "Milestone", "CarriedForward", "Terminal")][string]$ProgressFreshness = "Live"
    )

    $mutex = New-Object System.Threading.Mutex($false, "Global\OSUpgradeAutomationStatus")
    $lockTaken = $false
    try {
        try {
            $lockTaken = $mutex.WaitOne(15000)
        } catch [System.Threading.AbandonedMutexException] {
            $lockTaken = $true
        }
        if (-not $lockTaken) { throw "Timed out waiting for the shared upgrade-status writer lock." }

        $stage = Get-UpgradeStageMetadata -Phase $Phase
        $runId = Get-UpgradeRegistryValue -Name "RunId"
        if (-not $runId) { $runId = [guid]::NewGuid().ToString() }
        $priorSequence = [int](Get-UpgradeRegistryValue -Name "Sequence" -Default 0)
        $priorPhase = [int](Get-UpgradeRegistryValue -Name "Phase" -Default 0)
        $priorStatus = Get-UpgradeRegistryValue -Name "Status"
        $priorPhasePercent = Get-UpgradeRegistryValue -Name "PhasePercentComplete"
        $priorOverallPercent = [int](Get-UpgradeRegistryValue -Name "OverallPercentComplete" -Default 0)
        if ($script:StatusJson -and [System.IO.File]::Exists($script:StatusJson)) {
            try {
                $published = [System.IO.File]::ReadAllText($script:StatusJson) | ConvertFrom-Json -ErrorAction Stop
                if ($published.RunId -eq $runId -and $published.Sequence -gt $priorSequence) {
                    Write-Log "Reconciling migrated registry sequence $priorSequence with published sequence $($published.Sequence) for the same run."
                    $priorSequence = [int]$published.Sequence
                    $priorPhase = [int]$published.Phase
                    $priorStatus = $published.Status
                    $priorPhasePercent = $published.PhasePercentComplete
                    $priorOverallPercent = [math]::Max($priorOverallPercent, [int]$published.PercentComplete)
                }
            } catch {
                Write-Log "Could not reconcile the existing status JSON before publication: $_" "WARN"
            }
        }
        $terminalConflict = $priorStatus -in @("Completed", "CompletedWithWarnings", "Failed") -and
            $Status -ne $priorStatus -and -not ($Phase -eq 99 -and $Status -eq "Failed")
        if ($terminalConflict -or ($Status -eq "InProgress" -and $Phase -ge 3 -and $Phase -lt $priorPhase -and $priorPhase -le 7)) {
            Write-Log "Ignoring late phase publication $Phase/$Status after $priorPhase/$priorStatus." "WARN"
            return
        }
        $hasFreshPercent = $PercentComplete -ge 0 -and $Status -ne "Failed"

        if ($hasFreshPercent) {
            $phasePercent = [math]::Max(0, [math]::Min(100, $PercentComplete))
            if ($null -ne $priorPhasePercent -and $priorPhase -eq $Phase) {
                $phasePercent = [math]::Max($phasePercent, [int]$priorPhasePercent)
            }
        } elseif ($null -ne $priorPhasePercent -and ($priorPhase -eq $Phase -or $Status -eq "Failed")) {
            $phasePercent = [int]$priorPhasePercent
            if ($ProgressFreshness -ne "Terminal") {
                $ProgressFreshness = "CarriedForward"
            }
        } else {
            $phasePercent = 0
            if ($ProgressFreshness -ne "Terminal") {
                $ProgressFreshness = "Milestone"
            }
        }

        if (-not $hasFreshPercent) {
            $PercentSource = Get-UpgradeRegistryValue -Name "PercentSource" -Default $PercentSource
        }

        if (-not $ProgressSource) {
            if ($hasFreshPercent) {
                $ProgressSource = switch ($stage.Number) {
                    1 { "TaskCount.Precheck" }
                    2 { "TaskCount.Backup" }
                    default { "CallerSupplied" }
                }
            } else {
                $ProgressSource = Get-UpgradeRegistryValue -Name "ProgressSource" -Default "StageBoundary"
            }
        }

        $overallPercent = ConvertTo-OverallUpgradePercent -Phase $Phase -StageNumber $stage.Number `
            -StagePercentComplete $phasePercent -Status $Status
        if ($Status -eq "Failed") { $overallPercent = $priorOverallPercent }
        $overallPercent = [math]::Max($overallPercent, $priorOverallPercent)
        $overallPercent = [math]::Max(0, [math]::Min(100, $overallPercent))
        $stagePercent = if ($stage.Number -lt 3) {
            $phasePercent
        } else {
            [int][math]::Min(100, [math]::Max(0, [math]::Floor(100 * ($overallPercent - 25) / 70.0)))
        }

        $nowUtc = [DateTimeOffset]::UtcNow.ToString("o")
        $progressUpdatedAtUtc = if ($hasFreshPercent -or ($Status -ne "Failed" -and $overallPercent -gt $priorOverallPercent)) {
            $nowUtc
        } else {
            Get-UpgradeRegistryValue -Name "ProgressUpdatedAtUtc" -Default $nowUtc
        }
        $startTimeUtc = Get-UpgradeRegistryValue -Name "StartTimeUtc"
        if (-not $startTimeUtc) { $startTimeUtc = $nowUtc }
        $startTime = Get-UpgradeRegistryValue -Name "StartTime"
        if (-not $startTime) { $startTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss" }
        $sequence = 1 + $priorSequence

        Set-UpgradeRegistryValue -Name "SchemaVersion"            -Value 2 -Type DWord
        Set-UpgradeRegistryValue -Name "RunId"                    -Value $runId
        Set-UpgradeRegistryValue -Name "Sequence"                 -Value $sequence -Type DWord
        Set-UpgradeRegistryValue -Name "StageNumber"              -Value $stage.Number -Type DWord
        Set-UpgradeRegistryValue -Name "Stage"                    -Value $stage.Name
        Set-UpgradeRegistryValue -Name "Phase"                    -Value $Phase -Type DWord
        Set-UpgradeRegistryValue -Name "PhaseName"                -Value $PhaseName
        Set-UpgradeRegistryValue -Name "StagePercentComplete"     -Value $stagePercent -Type DWord
        Set-UpgradeRegistryValue -Name "PhasePercentComplete"     -Value $phasePercent -Type DWord
        Set-UpgradeRegistryValue -Name "OverallPercentComplete"   -Value $overallPercent -Type DWord
        Set-UpgradeRegistryValue -Name "PercentComplete"          -Value $overallPercent -Type DWord
        Set-UpgradeRegistryValue -Name "PercentSource"            -Value $PercentSource
        Set-UpgradeRegistryValue -Name "PercentStage"             -Value $stage.Name
        Set-UpgradeRegistryValue -Name "ProgressSource"           -Value $ProgressSource
        Set-UpgradeRegistryValue -Name "ProgressFreshness"        -Value $ProgressFreshness
        Set-UpgradeRegistryValue -Name "ProgressUpdatedAtUtc"     -Value $progressUpdatedAtUtc
        Set-UpgradeRegistryValue -Name "StatusUpdatedAtUtc"       -Value $nowUtc
        Set-UpgradeRegistryValue -Name "StartTime"                -Value $startTime
        Set-UpgradeRegistryValue -Name "StartTimeUtc"             -Value $startTimeUtc
        Set-UpgradeRegistryValue -Name "LastUpdated"              -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        if ($Phase -ge 5 -or $Status -ne "InProgress") {
            Set-UpgradeRegistryValue -Name "ExpectedDisconnect" -Value 0 -Type DWord
        }
        Set-UpgradeRegistryValue -Name "Notes"                    -Value $Notes
        # Commit terminal status after its percentage/evidence, so a reset
        # cannot leave Completed paired with the previous 95% publication.
        Set-UpgradeRegistryValue -Name "Status"                   -Value $Status

        Write-StatusJson

        $pctClause = " Overall=$overallPercent% Stage=$stagePercent% ($ProgressSource/$ProgressFreshness)"
        Write-Log "[$($stage.Name)] $PhaseName - Status=$Status$pctClause $Notes"

        try {
            $backupFolder = Get-UpgradeRegistryValue -Name "BackupFolder"
            if ($backupFolder -and (Test-Path $backupFolder)) {
                $progressLine = "[{0}] [{1}] Phase={2} ({3}) Status={4}{5} {6}" -f `
                    (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $stage.Name, $Phase, $PhaseName, $Status, $pctClause, $Notes
                Add-Content -Path (Join-Path $backupFolder "OSUpgradeProgress.log") -Value $progressLine -Encoding UTF8
            }
        } catch {
            Write-Log "Non-blocking: failed to mirror progress line to the backup folder: $_" "WARN"
        }
    } finally {
        if ($lockTaken) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Update-UpgradeBootEvidence {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 10 -ErrorAction Stop
        $bootTime = ([datetime]$os.LastBootUpTime).ToUniversalTime()
        $bootTimeUtc = $bootTime.ToString("o")
        $priorBootTimeUtc = Get-UpgradeRegistryValue -Name "LastObservedBootTimeUtc"
        $rebootCount = [int](Get-UpgradeRegistryValue -Name "RebootCount" -Default 0)
        $isNewBoot = [bool]($priorBootTimeUtc -and $priorBootTimeUtc -ne $bootTimeUtc)

        if ($isNewBoot) {
            $rebootCount++
        }

        # Event 12 can fire before Event Log service startup (6005). Query on
        # every monitor invocation so the later 6005-triggered run enriches
        # the same boot record without incrementing RebootCount a second time.
        $event12 = Get-WinEvent -FilterHashtable @{
            LogName = "System"; ProviderName = "Microsoft-Windows-Kernel-General"; Id = 12
            StartTime = $bootTime.AddMinutes(-5).ToLocalTime()
        } -MaxEvents 1 -ErrorAction SilentlyContinue
        $event6005 = Get-WinEvent -FilterHashtable @{
            LogName = "System"; ProviderName = "EventLog"; Id = 6005
            StartTime = $bootTime.AddMinutes(-5).ToLocalTime()
        } -MaxEvents 1 -ErrorAction SilentlyContinue

        $evidence = "LastBootUpTime=$bootTimeUtc; Event12={0}; Event6005={1}" -f `
            $(if ($event12) { $event12.TimeCreated.ToUniversalTime().ToString("o") } else { "not-found" }), `
            $(if ($event6005) { $event6005.TimeCreated.ToUniversalTime().ToString("o") } else { "not-found" })
        $priorEvidence = Get-UpgradeRegistryValue -Name "BootEvidence"
        if (-not $priorBootTimeUtc -or $isNewBoot -or $priorEvidence -ne $evidence) {
            Set-UpgradeRegistryValue -Name "LastObservedBootTimeUtc" -Value $bootTimeUtc
            Set-UpgradeRegistryValue -Name "RebootCount" -Value $rebootCount -Type DWord
            Set-UpgradeRegistryValue -Name "BootEvidence" -Value $evidence
        }
        return $isNewBoot
    } catch {
        Write-Log "Non-blocking: could not update reboot evidence: $_" "WARN"
    }
    return $false
}