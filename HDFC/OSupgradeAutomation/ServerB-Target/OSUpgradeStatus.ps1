<#
.SYNOPSIS
    Shared status/progress contract for the target-side OS upgrade scripts.

.DESCRIPTION
    PercentComplete is the monotonic, end-to-end percentage consumed by
    external systems. StagePercentComplete retains the local 0-100 progress
    for the current stage. The fixed workflow ranges are:

      Stage 1 - Prechecks             0-10
      Stage 2 - Backup               10-25
      Stage 3 - Windows Setup        25-95
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
    $range = switch ($StageNumber) {
        1 { [pscustomobject]@{ Start = 0; End = 10 } }
        2 { [pscustomobject]@{ Start = 10; End = 25 } }
        default { [pscustomobject]@{ Start = 25; End = 95 } }
    }
    return [int][math]::Floor($range.Start + (($range.End - $range.Start) * ($boundedStagePercent / 100.0)))
}

function Get-UpgradeStatusSnapshot {
    $registry = Get-ItemProperty -Path $script:RegRoot -ErrorAction SilentlyContinue
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
        SourceBuild                  = Get-SnapshotValue -Name "SourceBuild"
        TargetBuild                  = Get-SnapshotValue -Name "TargetBuild"
        SourceOSCaption              = Get-SnapshotValue -Name "SourceOSCaption"
        TargetOSCaption              = Get-SnapshotValue -Name "TargetOSCaption"
        PostUpgradeOSCaption         = Get-SnapshotValue -Name "PostUpgradeOSCaption"
        Notes                        = Get-SnapshotValue -Name "Notes"
        SetupLogTail                 = Get-SnapshotValue -Name "SetupLogTail"
        SetupTelemetryPercent        = Get-SnapshotValue -Name "SetupTelemetryPercent"
        SetupTelemetrySource         = Get-SnapshotValue -Name "SetupTelemetrySource"
        SetupProcessMissingSinceUtc  = Get-SnapshotValue -Name "SetupProcessMissingSinceUtc"
        SetupFailureDetectedAtUtc    = Get-SnapshotValue -Name "SetupFailureDetectedAtUtc"
        ServicesComparisonResult     = Get-SnapshotValue -Name "ServicesComparisonResult"
        ServicesComparisonReportPath = Get-SnapshotValue -Name "ServicesComparisonReportPath"
        ServicesAttentionCount       = Get-SnapshotValue -Name "ServicesAttentionCount"
        ServicesInfoCount            = Get-SnapshotValue -Name "ServicesInfoCount"
        LicenseRecommendation        = Get-SnapshotValue -Name "LicenseRecommendation"
        BackupFolder                 = Get-SnapshotValue -Name "BackupFolder"
        SystemStateBackupPath        = Get-SnapshotValue -Name "SystemStateBackupPath"
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
        $temporaryPath = "{0}.{1}.{2}.tmp" -f $script:StatusJson, $PID, ([guid]::NewGuid().ToString("N"))
        $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($temporaryPath, $json, $utf8WithoutBom)

        if ([System.IO.File]::Exists($script:StatusJson)) {
            try {
                [System.IO.File]::Replace($temporaryPath, $script:StatusJson, $null, $true)
            } catch {
                Move-Item -Path $temporaryPath -Destination $script:StatusJson -Force
            }
        } else {
            [System.IO.File]::Move($temporaryPath, $script:StatusJson)
        }

        $backupFolder = Get-UpgradeRegistryValue -Name "BackupFolder"
        if ($backupFolder -and (Test-Path $backupFolder)) {
            ($statusObject | ConvertTo-Json -Depth 6 -Compress) |
                Add-Content -Path (Join-Path $backupFolder "OSUpgradeStatusHistory.jsonl") -Encoding UTF8
        }
    } catch {
        Write-Log "Non-blocking: failed to write status JSON to $script:StatusJson : $_" "WARN"
    } finally {
        if ($temporaryPath -and (Test-Path $temporaryPath)) {
            Remove-Item -Path $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-Phase {
    param(
        [int]$Phase,
        [string]$PhaseName,
        [string]$Status = "InProgress",
        [Alias("StagePercentComplete")][int]$PercentComplete = -1,
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
        $priorStageNumber = Get-UpgradeRegistryValue -Name "StageNumber"
        $priorStagePercent = Get-UpgradeRegistryValue -Name "StagePercentComplete"
        $priorOverallPercent = [int](Get-UpgradeRegistryValue -Name "OverallPercentComplete" -Default 0)
        $hasFreshPercent = $PercentComplete -ge 0

        if ($hasFreshPercent) {
            $stagePercent = [math]::Max(0, [math]::Min(100, $PercentComplete))
            if ($null -ne $priorStagePercent -and [int]$priorStageNumber -eq $stage.Number) {
                $stagePercent = [math]::Max($stagePercent, [int]$priorStagePercent)
            }
        } elseif ($null -ne $priorStagePercent -and [int]$priorStageNumber -eq $stage.Number) {
            $stagePercent = [int]$priorStagePercent
            if ($ProgressFreshness -ne "Terminal") {
                $ProgressFreshness = "CarriedForward"
            }
        } else {
            $stagePercent = 0
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
            -StagePercentComplete $stagePercent -Status $Status
        $overallPercent = [math]::Max($overallPercent, $priorOverallPercent)
        $overallPercent = [math]::Max(0, [math]::Min(100, $overallPercent))

        $nowUtc = [DateTimeOffset]::UtcNow.ToString("o")
        $progressUpdatedAtUtc = if ($hasFreshPercent) {
            $nowUtc
        } else {
            Get-UpgradeRegistryValue -Name "ProgressUpdatedAtUtc" -Default $nowUtc
        }
        $runId = Get-UpgradeRegistryValue -Name "RunId"
        if (-not $runId) { $runId = [guid]::NewGuid().ToString() }
        $startTimeUtc = Get-UpgradeRegistryValue -Name "StartTimeUtc"
        if (-not $startTimeUtc) { $startTimeUtc = $nowUtc }
        $startTime = Get-UpgradeRegistryValue -Name "StartTime"
        if (-not $startTime) { $startTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss" }
        $sequence = 1 + [int](Get-UpgradeRegistryValue -Name "Sequence" -Default 0)

        Set-UpgradeRegistryValue -Name "SchemaVersion"            -Value 2 -Type DWord
        Set-UpgradeRegistryValue -Name "RunId"                    -Value $runId
        Set-UpgradeRegistryValue -Name "Sequence"                 -Value $sequence -Type DWord
        Set-UpgradeRegistryValue -Name "StageNumber"              -Value $stage.Number -Type DWord
        Set-UpgradeRegistryValue -Name "Stage"                    -Value $stage.Name
        Set-UpgradeRegistryValue -Name "Phase"                    -Value $Phase -Type DWord
        Set-UpgradeRegistryValue -Name "PhaseName"                -Value $PhaseName
        Set-UpgradeRegistryValue -Name "Status"                   -Value $Status
        Set-UpgradeRegistryValue -Name "StagePercentComplete"     -Value $stagePercent -Type DWord
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
        Set-UpgradeRegistryValue -Name "ExpectedDisconnect"       -Value $(if ($Phase -eq 4) { 1 } else { 0 }) -Type DWord
        Set-UpgradeRegistryValue -Name "Notes"                    -Value $Notes

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
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
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