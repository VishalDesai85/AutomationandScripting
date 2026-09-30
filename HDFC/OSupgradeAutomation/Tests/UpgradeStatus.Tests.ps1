# Run with powershell.exe -NoProfile -File .\UpgradeStatus.Tests.ps1.
# Only AST-extracted functions/main statements run; all operational commands
# below are in-memory mocks. The production scripts are never invoked.
$ErrorActionPreference = 'Stop'
$targetDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'ServerB-Target'
$asts = @{}
foreach ($name in @('OSUpgradeShared.ps1', 'Update-UpgradeStatus.ps1', 'Remove-UpgradeArtifacts.ps1')) {
    $tokens = $null
    $errors = $null
    $asts[$name] = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $targetDir $name), [ref]$tokens, [ref]$errors)
    if ($errors) { throw ($errors.Message -join "`n") }
}
$functionsToLoad = @('Set-UpgradeRegistryValue', 'Get-UpgradeRegistryValue', 'Get-UpgradeRegistrySnapshot',
    'Get-SnapshotValue', 'Write-StatusJson', 'Set-Phase', 'Invoke-PostUpgradeValidation',
    'Resolve-CleanupLogPath', 'Write-CleanupLog', 'Assert-NoUpgradeReparsePoint', 'Assert-UpgradeCleanupPath',
    'Invoke-UpgradeArtifactCleanup')
foreach ($ast in $asts.Values) {
    foreach ($definition in $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)) {
        if ($definition.Name -in $functionsToLoad) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }
}
$statusAst = $asts['Update-UpgradeStatus.ps1']
$mainTry = $statusAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] }
$mainStart = $false
$mainStatements = foreach ($statement in $mainTry.Body.Statements) {
    if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $statement.Left.Extent.Text -eq '$currentBuild') { $mainStart = $true }
    if ($mainStart) { $statement.Extent.Text }
}
if (-not $mainStart) { throw 'Could not isolate status polling statements.' }
. ([scriptblock]::Create("function Invoke-TestStatusPoll {`n$($mainStatements -join "`n")`n}"))

$script:assertions = 0
function Assert-Equal($Actual, $Expected, [string]$Because) {
    $script:assertions++
    if ($Actual -cne $Expected) { throw "$Because : expected '$Expected', got '$Actual'." }
}
function Assert-Throws([scriptblock]$Action, [string]$Because) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-Equal $threw $true $Because
}
function Reset-Fixture {
    $script:RegRoot = 'HKLM:\SOFTWARE\OSUpgradeAutomation'
    $script:BaseDir = 'C:\ProgramData\OSUpgradeAutomation'
    $script:MarkerOOBE = "$script:BaseDir\postoobe.marker"
    $script:MarkerRB = "$script:BaseDir\rollback.marker"
    $script:LogDir = "$script:BaseDir\Logs"
    $script:state = @{
        Status = 'InProgress'; Phase = 3; SourceBuild = '14393'; TargetBuild = '17763'
        SourceEditionId = 'ServerStandard'; PreUpgradeLicenseStatus = 'Licensed'
        BackupFolder = 'D:\UpgradeBackup\run'; PreUpgradeServicesSnapshot = 'D:\UpgradeBackup\run\Services.csv'
        StatusJsonPath = 'D:\upgrade_status.json'
    }
    $script:paths = @{}
    foreach ($p in @($script:RegRoot, $script:BaseDir, $script:state.BackupFolder,
        $script:state.PreUpgradeServicesSnapshot, $script:state.StatusJsonPath)) { $script:paths[$p] = $true }
    $script:build = '17763'
    $script:setupInProgress = 0
    $script:jsonSuccess = $true
    $script:jsonWrites = 0
    $script:StatusJsonPublished = $false
    $script:writes = @()
    $script:removed = @()
    $script:unregistered = @()
    $script:tasks = @([pscustomobject]@{ TaskName = 'OSUpgradePhaseMonitor' })
    $script:failUnregister = $false
    $script:failRemove = ''
    $script:failStateRead = $false
    $script:failBuildRead = $false
    $script:failComparison = $false
    $script:reparsePaths = @()
    $script:containerPaths = @($script:BaseDir)
    $script:children = @{}
    $script:setupProcesses = @()
    $script:services = @([pscustomobject]@{ Name = 'RpcSs'; DisplayName = 'RPC'; Status = 'Running'; StartType = 'Automatic' })
    $script:licenses = @([pscustomobject]@{
        ApplicationID = '55c92734-d682-4d71-983e-d6ec3f16059f'; PartialProductKey = 'TEST'; LicenseStatus = 1
    })
}
function Write-Log { param($Message, $Level) }
function Join-Path { param($Path, $ChildPath) return [IO.Path]::Combine($Path, $ChildPath) }
function Get-UpgradeRegistryValue { param($Name, $Default = $null)
    if ($script:state.ContainsKey($Name)) { return $script:state[$Name] }
    return $Default
}
function Set-UpgradeRegistryValue { param($Name, $Value, $Type)
    $script:writes += $Name
    $script:state[$Name] = $Value
}
function Write-StatusJson { $script:jsonWrites++; return $script:jsonSuccess }
function Remove-ItemProperty { param($Path, $Name, $ErrorAction) $script:state.Remove($Name) }
function Test-Path { param($Path, $LiteralPath, $PathType, $ErrorAction)
    $p = if ($LiteralPath) { $LiteralPath } else { $Path }
    if ($PathType -eq 'Leaf' -and $p -in $script:containerPaths) { return $false }
    return [bool]$script:paths[$p]
}
function Get-ItemProperty { param($Path, $LiteralPath, $Name, $ErrorAction)
    $p = if ($LiteralPath) { $LiteralPath } else { $Path }
    if ($p -eq $script:RegRoot) {
        if ($script:failStateRead) { throw 'Mock registry read failure' }
        return [pscustomobject]$script:state
    }
    if ($p -eq 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion') {
        if ($script:failBuildRead) { throw 'Mock build read failure' }
        return [pscustomobject]@{ CurrentBuildNumber = $script:build; EditionID = 'ServerStandard' }
    }
    if ($p -eq 'HKLM:\SYSTEM\Setup') { return [pscustomobject]@{ SystemSetupInProgress = $script:setupInProgress } }
    throw "Unexpected property read: $p"
}
function Get-CimInstance { param($ClassName, $Filter, $ErrorAction)
    if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{ Caption = 'Windows Server' } }
    if ($ClassName -eq 'SoftwareLicensingProduct') { return $script:licenses }
    throw "Unexpected CIM class: $ClassName"
}
function Get-Service { param($Name, $ErrorAction)
    if ($Name) { return [pscustomobject]@{ Name = $Name; Status = 'Running' } }
    return $script:services
}
function Import-Csv { param($Path)
    if ($script:failComparison) { throw 'Mock snapshot read failure' }
    return @([pscustomobject]@{ Name = 'RpcSs'; DisplayName = 'RPC'; Status = 'Running'; StartType = 'Automatic' })
}
function Out-File { param([Parameter(ValueFromPipeline)]$InputObject, $FilePath, $Encoding, [switch]$Force) process {} }
function Add-Content { param($Path, $Value, $Encoding) }
function Copy-Item { param($Path, $Destination, [switch]$Force, $ErrorAction) }
function Get-Process { param($Name, $ErrorAction) return $script:setupProcesses }
function Get-SetupLogTail { param($Path) return $null }
function Get-SetupProgressPercent { param($LogPath) return $null }
function Get-ScheduledTaskInfo { param($TaskName, $ErrorAction) return [pscustomobject]@{ LastTaskResult = 0 } }
function Get-ScheduledTask { param($TaskPath, $ErrorAction) return $script:tasks }
function Unregister-ScheduledTask { param($TaskName, $TaskPath, $Confirm, $ErrorAction)
    if ($script:failUnregister) { throw 'Mock task access denied' }
    $script:unregistered += $TaskName
}
function Remove-Item { param($Path, $LiteralPath, [switch]$Force, [switch]$Recurse, $ErrorAction)
    if (-not $LiteralPath) { throw 'Deletion must use LiteralPath' }
    if ($LiteralPath -eq $script:failRemove) { throw 'Mock deletion failed' }
    $script:removed += $LiteralPath
    $script:paths.Remove($LiteralPath)
}
function Get-Item { param($LiteralPath, [switch]$Force, $ErrorAction)
    return [pscustomobject]@{
        Attributes = $(if ($LiteralPath -in $script:reparsePaths) { [IO.FileAttributes]::ReparsePoint } else { [IO.FileAttributes]::Normal })
        PSIsContainer = $LiteralPath -in $script:containerPaths
    }
}
function Get-ChildItem { param($LiteralPath, [switch]$Force, $ErrorAction)
    return @($script:children[$LiteralPath] | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ FullName = $_ } })
}

Reset-Fixture
$script:state.Phase = 5
Set-Phase -Phase 3 -PhaseName 'Downlevel'
Assert-Equal $script:state.Phase 5 'Late downlevel telemetry cannot regress first boot'
Assert-Equal $script:writes.Count 0 'Rejected transition writes nothing'
foreach ($terminal in @('Completed', 'CompletedWithWarnings', 'Failed')) {
    Reset-Fixture
    $script:state.Status = $terminal
    Set-Phase -Phase 4 -PhaseName 'Safe OS'
    Assert-Equal $script:state.Status $terminal 'Terminal status cannot be reopened'
}
Reset-Fixture
$script:state.Status = 'Completed'
Set-Phase -Phase 99 -PhaseName 'Rolled Back' -Status Failed -PercentComplete 0
Assert-Equal $script:state.Status 'Failed' 'Confirmed rollback overrides prior completion'
Assert-Equal $script:state.Phase 99 'Rollback retains its distinct phase'
Assert-Equal ($script:writes.IndexOf('Status') -gt $script:writes.IndexOf('PercentComplete')) $true 'Terminal status published after percentage'
Reset-Fixture
$script:state.PercentStage = 'Stage 2/3: Backup'
$script:state.PercentComplete = 100
Set-Phase -Phase 3 -PhaseName 'Downlevel'
Assert-Equal $script:state.ContainsKey('PercentComplete') $false 'New stage clears old percentage'
Reset-Fixture
$script:state.PercentStage = 'Stage 3/3: Windows Setup Execution'
$script:state.PercentComplete = 72
$script:state.PercentSource = 'Measured'
$script:state.ProgressUpdatedAtUtc = '2026-09-30T08:00:00.0000000Z'
$script:state.ProgressHighWaterPercent = 72
$script:state.ProgressHighWaterStage = 'Stage 3/3: Windows Setup Execution'
Set-Phase -Phase 4 -PhaseName 'Safe OS'
Assert-Equal $script:state.PercentComplete 72 'Missing telemetry carries the last verified percentage'
Assert-Equal $script:state.ProgressFreshness 'CarriedForward' 'Missing telemetry is explicitly carried forward'
Assert-Equal $script:state.ProgressUpdatedAtUtc '2026-09-30T08:00:00.0000000Z' 'Carried progress preserves its original timestamp'
Set-Phase -Phase 4 -PhaseName 'Windows Setup Failed' -Status Failed -PercentComplete 0
Assert-Equal $script:state.PercentComplete 72 'Terminal failure retains the verified stage high-water'
Assert-Equal $script:state.ProgressHighWaterPercent 72 'Terminal failure does not lower stage high-water'
Assert-Equal $script:state.ProgressFreshness 'Terminal' 'Retained terminal progress is labelled terminal'
Assert-Equal $script:state.ProgressUpdatedAtUtc '2026-09-30T08:00:00.0000000Z' 'Terminal retention does not fabricate a new progress timestamp'
Reset-Fixture
$script:state.Phase = 0
Set-Phase -Phase 1 -PhaseName 'Pre-Upgrade Assessment' -PercentComplete 25 -PercentSource Measured -ProgressFreshness Milestone
Assert-Equal $script:state.ProgressFreshness 'Milestone' 'Task-count progress is identified as a milestone'
Assert-Equal ([string]::IsNullOrWhiteSpace($script:state.StatusUpdatedAtUtc)) $false 'Every accepted status update receives a UTC timestamp'
Assert-Equal ([string]::IsNullOrWhiteSpace($script:state.ProgressUpdatedAtUtc)) $false 'A new verified percentage receives a UTC timestamp'
foreach ($missingEvidence in @('TargetBuild', 'PostUpgradeBuild', 'PostUpgradeValidationTime', 'PostUpgradeValidationResult')) {
    Reset-Fixture
    $script:state.PostUpgradeBuild = $script:state.TargetBuild
    $script:state.PostUpgradeValidationTime = '2026-09-26T08:00:00.0000000Z'
    $script:state.PostUpgradeValidationResult = 'Passed'
    $script:state.Remove($missingEvidence)
    Assert-Throws { Set-Phase -Phase 7 -PhaseName Completed -Status Completed -PercentComplete 100 } 'Completion requires every validation evidence field'
    Assert-Equal $script:state.Status 'InProgress' 'Missing evidence cannot publish completion'
}
Reset-Fixture
$script:state.PostUpgradeBuild = $script:state.SourceBuild
$script:state.PostUpgradeValidationTime = '2026-09-26T08:00:00.0000000Z'
$script:state.PostUpgradeValidationResult = 'Passed'
Assert-Throws { Set-Phase -Phase 7 -PhaseName Completed -Status CompletedWithWarnings -PercentComplete 100 } 'Warnings cannot bypass target build verification'

foreach ($badBuild in @('14393', '', $null)) {
    Reset-Fixture
    $script:build = $badBuild
    Invoke-PostUpgradeValidation
    Assert-Equal $script:state.Status 'Failed' 'Build mismatch or missing build is not completion'
    Assert-Equal $script:state.PercentComplete 0 'Unverified build is never 100 percent'
}
Reset-Fixture
$script:state.Remove('TargetBuild')
Invoke-PostUpgradeValidation
Assert-Equal $script:state.Status 'Failed' 'Missing target build cannot complete'
Reset-Fixture
$script:failBuildRead = $true
Invoke-PostUpgradeValidation
Assert-Equal $script:state.Status 'Failed' 'Build read error cannot complete'
Reset-Fixture
Invoke-PostUpgradeValidation
Assert-Equal $script:state.Status 'Completed' 'Verified healthy upgrade completes'
Assert-Equal $script:state.PercentComplete 100 'Verified completion reports 100 percent'
Assert-Equal $script:state.PostUpgradeBuild '17763' 'Completion stores the locally verified build'
Assert-Equal $script:state.PostUpgradeValidationResult 'Passed' 'Completion stores successful validation evidence'
Assert-Equal ([string]::IsNullOrWhiteSpace($script:state.PostUpgradeValidationTime)) $false 'Completion timestamps validation'
Assert-Equal $script:unregistered.Count 3 'Successful validation removes all monitor/launch tasks'
Reset-Fixture
$script:licenses[0].ApplicationID = 'Office-not-Windows'
Invoke-PostUpgradeValidation
Assert-Equal $script:state.Status 'CompletedWithWarnings' 'Licensed non-Windows products cannot mask OS activation'
Assert-Equal ($script:state.LicenseRecommendation -match 'NOT Licensed now') $true 'OS activation warning recorded'
foreach ($failure in @('missing', 'unreadable')) {
    Reset-Fixture
    if ($failure -eq 'missing') { $script:state.Remove('PreUpgradeServicesSnapshot') } else { $script:failComparison = $true }
    Invoke-PostUpgradeValidation
    Assert-Equal $script:state.Status 'CompletedWithWarnings' 'Unavailable services validation is not silent success'
}
Reset-Fixture
$script:jsonSuccess = $false
Invoke-PostUpgradeValidation
Assert-Equal $script:state.Status 'Completed' 'Registry keeps verified outcome on JSON failure'
Assert-Equal $script:unregistered.Count 0 'JSON failure keeps monitor for retry'
Invoke-TestStatusPoll
Assert-Equal $script:unregistered.Count 0 'Terminal retry retains monitor while JSON fails'
$script:jsonSuccess = $true
Invoke-TestStatusPoll
Assert-Equal $script:unregistered.Count 3 'Terminal JSON retry success retires monitors'
Reset-Fixture
$script:paths[$script:MarkerRB] = $true
Invoke-TestStatusPoll
Assert-Equal $script:state.Phase 99 'Rollback marker takes priority'
Assert-Equal ($script:unregistered -contains 'OSUpgradeRebootWatcher') $true 'Rollback removes reboot watcher'
Reset-Fixture
$script:state.SourceBuild = $script:state.TargetBuild
$script:paths[$script:MarkerOOBE] = $true
Invoke-TestStatusPoll
Assert-Equal $script:state.Status 'Completed' 'Same-build upgrade completes through its OOBE marker'
foreach ($phase in @(3, 5, 6)) {
    Reset-Fixture
    $script:state.Phase = $phase
    $RebootEvent = $true
    Invoke-TestStatusPoll
    Assert-Equal $script:state.Phase $(if ($phase -eq 3) { 4 } else { $phase }) 'Reboot events affect only downlevel'
}
$RebootEvent = $false

Reset-Fixture
$script:build = $script:state.SourceBuild
$script:state.SetupWasObserved = 1
$script:paths["$env:SystemDrive\`$WINDOWS.~BT"] = $true
Invoke-TestStatusPoll
Assert-Equal $script:state.Phase 3 'First missing Setup observation remains in Downlevel'
Assert-Equal ([string]::IsNullOrWhiteSpace($script:state.SetupMissingSinceUtc)) $false 'First missing Setup observation starts the confirmation window'
Assert-Equal $script:state.Status 'InProgress' 'Missing Setup does not fail before the confirmation threshold'
Reset-Fixture
$script:build = $script:state.SourceBuild
$script:state.SetupWasObserved = 1
$script:state.SetupLastObservedAtUtc = '2026-09-30T07:00:00.0000000Z'
$script:state.SetupMissingSinceUtc = (Get-Date).ToUniversalTime().AddMinutes(-11).ToString('o')
$script:state.PercentStage = 'Stage 3/3: Windows Setup Execution'
$script:state.PercentComplete = 63
$script:state.ProgressUpdatedAtUtc = '2026-09-30T07:05:00.0000000Z'
$script:paths["$env:SystemDrive\`$WINDOWS.~BT"] = $true
Invoke-TestStatusPoll
Assert-Equal $script:state.Status 'Failed' 'Setup missing for ten minutes without reboot evidence becomes terminal failure'
Assert-Equal $script:state.PercentComplete 63 'Dead-Setup failure retains the highest verified progress'
Assert-Equal ($script:state.Notes -match 'LastTaskResult=0') $true 'Dead-Setup failure includes scheduled-task diagnostics'
Reset-Fixture
$script:build = $script:state.SourceBuild
$script:state.SetupWasObserved = 1
$script:state.ExpectedDisconnect = 1
$script:state.SetupMissingSinceUtc = (Get-Date).ToUniversalTime().AddMinutes(-11).ToString('o')
$script:paths["$env:SystemDrive\`$WINDOWS.~BT"] = $true
Invoke-TestStatusPoll
Assert-Equal $script:state.Status 'InProgress' 'Expected reboot disconnect suppresses dead-Setup failure'
Assert-Equal $script:state.Phase 4 'Expected reboot disconnect moves to inferred Safe OS'

Reset-Fixture
$script:build = $script:state.SourceBuild
$script:setupProcesses = @([pscustomobject]@{ Name = 'setuphost' })
$script:state.ExpectedDisconnect = 1
$script:paths["$env:SystemDrive\`$WINDOWS.~BT"] = $true
Invoke-TestStatusPoll
Assert-Equal $script:state.Phase 3 'Active source-build setup stays downlevel'
Assert-Equal $script:state.Status 'InProgress' 'Active setup is not completed prematurely'
Assert-Equal $script:state.ExpectedDisconnect 1 'Active Setup poll cannot erase Event 1074 evidence before shutdown'
Reset-Fixture
$script:setupInProgress = 1
Invoke-TestStatusPoll
Assert-Equal $script:state.Phase 5 'Target build during Setup is first boot'
Assert-Equal $script:state.Status 'InProgress' 'First boot does not run premature validation'
Reset-Fixture
Invoke-TestStatusPoll
Assert-Equal $script:state.Status 'Completed' 'Changed-build fallback validates when Setup is finished'
Reset-Fixture
$script:setupInProgress = $null
Invoke-TestStatusPoll
Assert-Equal $script:state.Status 'InProgress' 'Missing Setup state is not treated as finished'
Reset-Fixture
$script:state.SourceBuild = $script:state.TargetBuild
Invoke-TestStatusPoll
Assert-Equal $script:state.Status 'InProgress' 'Same-build equality alone cannot prove completion'

& {
    $writer = $statusAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-StatusJson'
    }, $true)
    . ([scriptblock]::Create($writer.Extent.Text))
    function Move-Item { param($Path, $Destination, [switch]$Force)
        if (-not $script:jsonSuccess) { throw 'Mock atomic publish failure' }
    }
    Reset-Fixture
    $script:StatusJson = 'D:\upgrade_status.json'
    Assert-Equal (Write-StatusJson) $true 'JSON writer reports successful publication'
    $script:jsonSuccess = $false
    Assert-Equal (Write-StatusJson) $false 'JSON writer reports failed publication for retry'
}

foreach ($status in @($null, '', 'InProgress', 'Unexpected')) {
    Reset-Fixture
    $script:state.Status = $status
    Invoke-UpgradeArtifactCleanup | Out-Null
    Assert-Equal $script:removed.Count 0 'Unknown or nonterminal cleanup is fail-closed'
    Assert-Equal $script:unregistered.Count 0 'Skipped cleanup does not unregister itself'
}
Reset-Fixture
$script:paths.Remove($script:RegRoot)
Invoke-UpgradeArtifactCleanup | Out-Null
Assert-Equal $script:removed.Count 0 'Missing registry does not authorize cleanup'
Reset-Fixture
$script:failStateRead = $true
Assert-Throws { Invoke-UpgradeArtifactCleanup } 'Unreadable state fails closed'
Assert-Equal $script:removed.Count 0 'Registry read failure deletes nothing'
Reset-Fixture
$script:state.Status = 'Completed'
Invoke-UpgradeArtifactCleanup | Out-Null
Assert-Equal ($script:removed -join '|') "D:\upgrade_status.json|$script:BaseDir|$script:RegRoot" 'Cleanup removes registry last and never backup'
Reset-Fixture
Invoke-UpgradeArtifactCleanup -Force | Out-Null
Assert-Equal $script:removed.Count 3 'Explicit Force bypasses only terminal guard'
foreach ($unsafePath in @('D:\', 'D:\backup', 'relative.json', '\\server\share\status.json')) {
    Reset-Fixture
    $script:state.StatusJsonPath = $unsafePath
    Assert-Throws { Invoke-UpgradeArtifactCleanup -Force } 'Unsafe status path refused even with Force'
    Assert-Equal $script:unregistered.Count 0 'Path validation precedes mutation'
}
Reset-Fixture
$script:state.Status = 'Failed'
$script:containerPaths += $script:state.StatusJsonPath
Assert-Throws { Invoke-UpgradeArtifactCleanup } 'Directory named JSON cannot be deleted'
Reset-Fixture
$script:state.Status = 'Completed'
$script:reparsePaths = @("$script:BaseDir\junction")
$script:children[$script:BaseDir] = $script:reparsePaths
Assert-Throws { Invoke-UpgradeArtifactCleanup } 'Reparse point beneath artifact directory blocks recursion'
Assert-Equal $script:removed.Count 0 'Unsafe artifact tree deletes nothing'
Reset-Fixture
$script:state.Status = 'Completed'
$script:paths['D:\'] = $true
$script:reparsePaths = @('D:\')
Assert-Throws { Invoke-UpgradeArtifactCleanup } 'Status file ancestor reparse point blocks cleanup'
Assert-Equal $script:unregistered.Count 0 'Ancestor checks precede task removal'
Reset-Fixture
$script:state.Status = 'Completed'
$script:state.StatusJsonPath = 'D:\upgrade_status[1].json'
$script:paths[$script:state.StatusJsonPath] = $true
Invoke-UpgradeArtifactCleanup | Out-Null
Assert-Equal $script:removed[0] 'D:\upgrade_status[1].json' 'Wildcard characters are removed literally'
foreach ($failedOperation in @('task', 'json', 'folder')) {
    Reset-Fixture
    $script:state.Status = 'Completed'
    if ($failedOperation -eq 'task') { $script:failUnregister = $true }
    if ($failedOperation -eq 'json') { $script:failRemove = $script:state.StatusJsonPath }
    if ($failedOperation -eq 'folder') { $script:failRemove = $script:BaseDir }
    Assert-Throws { Invoke-UpgradeArtifactCleanup } 'Cleanup failure is not reported as success'
    Assert-Equal ($script:removed -contains $script:RegRoot) $false 'Failed cleanup preserves retry metadata'
}
Write-Output "PASS: $script:assertions isolated upgrade status/cleanup assertions; both production scripts parse."
