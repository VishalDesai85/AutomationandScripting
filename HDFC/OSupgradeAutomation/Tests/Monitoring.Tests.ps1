$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Read-TestAst($RelativePath) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root $RelativePath), [ref]$tokens, [ref]$errors)
    if ($errors) { throw ($errors.Message -join "`n") }
    return $ast
}
$orchestrator = Read-TestAst 'ServerA-Orchestrator\Start-RemoteUpgradeOrchestrator.ps1'
$starter = Read-TestAst 'ServerB-Target\Start-TargetUpgrade.ps1'
$script:assertions = 0
function Assert-Equal($Actual, $Expected, $Message) {
    $script:assertions++
    if ($Actual -cne $Expected) { throw "$Message : expected '$Expected', got '$Actual'." }
}
function Find-Function($Ast, $Name) {
    $definition = $Ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)
    if (-not $definition) { throw "Missing function $Name" }
    return $definition
}
foreach ($name in @('Show-ProgressBar', 'Get-PhaseChecklist')) {
    . ([scriptblock]::Create((Find-Function $orchestrator $name).Extent.Text))
}
function Write-Progress {
    param($Id, $Activity, $Status, $CurrentOperation, $PercentComplete)
    $script:progress = $PSBoundParameters
}
$script:PhaseShortNames = @{ 3 = 'Downlevel'; 4 = 'Safe OS'; 5 = 'First Boot'; 7 = 'Validation' }
$TargetComputer = 'Fixture'
Show-ProgressBar -PercentComplete $null -PhaseName Downlevel -Status InProgress -Mode ActivePolling -Phase 3
Assert-Equal $script:progress.PercentComplete -1 'Missing Setup counter renders an indeterminate bar'
Assert-Equal ($script:progress.Status -match 'Awaiting measured progress') $true 'Unknown progress is not labelled zero percent'
foreach ($percent in @(0, 72, 100)) {
    Show-ProgressBar -PercentComplete $percent -PhaseName Downlevel -Status InProgress -Mode ActivePolling -Phase 3
    Assert-Equal $script:progress.PercentComplete $percent 'Measured progress preserves the exact value'
}

$refreshFunction = Find-Function $orchestrator 'Request-RemoteMonitorRefresh'
$refreshBlock = $refreshFunction.Find({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-Command'
}, $true).CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }
$remoteRefresh = [scriptblock]::Create($refreshBlock.ScriptBlock.Extent.Text.Trim([char[]]'{}'))
function Get-ItemProperty {
    param($LiteralPath)
    if ($LiteralPath -eq 'HKLM:\SOFTWARE\OSUpgradeAutomation') { return $script:fixtureState }
    return [pscustomobject]@{ CurrentBuildNumber = '26100' }
}
function Get-ScheduledTask {
    param($TaskName, $ErrorAction)
    if ($script:taskMissing) { throw 'Task is missing' }
    return [pscustomobject]@{ TaskName = $TaskName; State = $script:taskState }
}
function Get-ScheduledTaskInfo { param($TaskName, $ErrorAction) [pscustomobject]@{ LastTaskResult = $script:probeTaskResult } }
function Start-ScheduledTask { param($TaskName, $ErrorAction) $script:taskStarts++ }
$script:fixtureState = [pscustomobject]@{ Status = 'InProgress'; Phase = 3; TargetBuild = '26100' }
$readFunction = Find-Function $orchestrator 'Get-RemoteStatusViaWinRM'
$readBlock = $readFunction.Find({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-Command'
}, $true).CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }
$remoteRead = [scriptblock]::Create($readBlock.ScriptBlock.Extent.Text.Trim([char[]]'{}'))
function Test-Path { param($LiteralPath) $true }
function Get-Content { param($LiteralPath, [switch]$Raw) throw 'Stale JSON should not be read ahead of registry' }
$readResult = & $remoteRead 'D:\upgrade_status.json'
Assert-Equal $readResult.Phase 3 'WinRM reads the registry ahead of stale JSON'
Assert-Equal ($readResult.PSObject.Properties.Name -contains 'PostUpgradeValidationResult') $true 'WinRM payload retains completion evidence fields'
$script:taskState = 'Ready'
$script:taskMissing = $false
$script:taskStarts = 0
$script:probeTaskResult = 0
$result = & $remoteRefresh
Assert-Equal $script:taskStarts 1 'Refresh starts only the existing monitor'
Assert-Equal $result.CurrentBuild '26100' 'Refresh diagnostics reveal the live booted build'
Assert-Equal $result.RefreshRequested $true 'Refresh explicitly reports whether a monitor was started'
Assert-Equal $script:fixtureState.Phase 3 'Refresh never fabricates completion from a live build'
$script:taskState = 'Running'
$result = & $remoteRefresh
Assert-Equal $script:taskStarts 1 'Refresh does not restart a monitor currently validating'
Assert-Equal $result.RefreshRequested $false 'Running monitor reports no additional start'
$script:taskState = 'Ready'
$script:fixtureState.Status = 'Completed'
$result = & $remoteRefresh
Assert-Equal $script:taskStarts 1 'Refresh cannot restart monitoring after completion'
$script:taskMissing = $true
$threw = $false
try { & $remoteRefresh | Out-Null } catch { $threw = $true }
Assert-Equal $threw $true 'Missing monitor produces an explicit diagnostic failure'

. ([scriptblock]::Create($refreshFunction.Extent.Text))
function Get-WinRMSessionParams { @{ ComputerName = 'Fixture' } }
function Invoke-Command { param($ComputerName, [switch]$AsJob, $ScriptBlock) 'fixture-job' }
function Wait-Job { param($Job, $Timeout) if (-not $script:refreshTimeout) { $Job } }
function Receive-Job { param($Job, $ErrorAction) $script:refreshResult }
function Stop-Job { param($Job, $ErrorAction) }
function Remove-Job { param($Job, [switch]$Force, $ErrorAction) $script:jobsRemoved++ }
function Write-Log { param($Message, $Level) $script:messages += "$Level $Message" }
$script:messages = @()
$script:refreshTimeout = $true
$script:jobsRemoved = 0
Request-RemoteMonitorRefresh
Assert-Equal $script:jobsRemoved 1 'Timed-out refresh disposes its remote job'
Assert-Equal (($script:messages -join '|') -match 'WARN.+timed out') $true 'Refresh timeout is surfaced rather than silently ignored'
$script:refreshTimeout = $false
$script:refreshResult = [pscustomobject]@{
    CurrentBuild = '26100'; TargetBuild = '26100'; TaskState = 'Ready'
    LastTaskResult = 5; RefreshRequested = $true
}
$script:messages = @()
Request-RemoteMonitorRefresh
Assert-Equal (($script:messages -join '|') -match 'WARN.+LastTaskResult=5') $true 'Failed task result points operators to monitor diagnostics'

$monitorLoop = $orchestrator.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.WhileStatementAst] -and $_.Extent.Text -match 'Request-RemoteMonitorRefresh'
}
$staleStatements = @()
$collect = $false
foreach ($statement in $monitorLoop.Body.Statements) {
    if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst]) {
        if ($statement.Left.Extent.Text -eq '$statusIsStale') { $collect = $true }
        if ($statement.Left.Extent.Text -eq '$progressAgeSec') { $collect = $false }
    }
    if ($collect) { $staleStatements += $statement.Extent.Text }
}
if (-not $staleStatements.Count) { throw 'Could not isolate stale-status decision.' }
$staleDecision = [scriptblock]::Create($staleStatements -join "`n")
function Request-RemoteMonitorRefresh { $script:refreshes++ }
foreach ($case in @(
    @{ Age = 149; Mode = 'ActivePolling'; Previous = 'ActivePolling'; Since = 61; Stale = $false; Refresh = 0 },
    @{ Age = 150; Mode = 'ActivePolling'; Previous = 'ActivePolling'; Since = 61; Stale = $true; Refresh = 1 },
    @{ Age = 150; Mode = 'ActivePolling'; Previous = 'ActivePolling'; Since = 59; Stale = $true; Refresh = 0 },
    @{ Age = 800; Mode = 'Offline'; Previous = 'ActivePolling'; Since = 61; Stale = $true; Refresh = 0 },
    @{ Age = 30; Mode = 'ActivePolling'; Previous = 'Offline'; Since = 61; Stale = $false; Refresh = 1 }
)) {
    $evidenceAgeSec = $case.Age
    $status = [pscustomobject]@{ Status = 'InProgress'; Mode = $case.Mode; PhaseName = 'Downlevel Phase' }
    $lastMode = $case.Previous
    $lastMonitorRefreshAt = (Get-Date).AddSeconds(-$case.Since)
    $staleStatusWarningReported = $false
    $displayPhaseName = $status.PhaseName
    $script:refreshes = 0
    . $staleDecision
    Assert-Equal $statusIsStale $case.Stale "Staleness boundary at $($case.Age) seconds"
    Assert-Equal $script:refreshes $case.Refresh 'Refresh honors reconnect, reachability and throttle'
    if ($case.Stale) { Assert-Equal ($displayPhaseName -match 'STALE snapshot') $true 'Frozen Downlevel is labelled unconfirmed' }
}
$status = [pscustomobject]@{ Status = 'Completed'; Mode = 'ActivePolling'; PhaseName = 'Completed' }
$lastMode = 'Offline'
$lastMonitorRefreshAt = [datetime]::MinValue
$script:refreshes = 0
. $staleDecision
Assert-Equal $script:refreshes 0 'Completed state does not request a now-unregistered monitor'

$probeStatements = @()
$collect = $false
$starterTry = $starter.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] }
$bodyTry = $starterTry.Body.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] }
foreach ($statement in $bodyTry.Body.Statements) {
    if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $statement.Left.Extent.Text -eq '$probeAction') { $collect = $true }
    if ($collect) { $probeStatements += $statement.Extent.Text }
    if ($collect -and $statement.Extent.Text -match '^Write-Log "Verified SYSTEM phase monitor') { break }
}
if (-not $probeStatements.Count) { throw 'Could not isolate monitor preflight.' }
$probe = [scriptblock]::Create($probeStatements -join "`n")
function New-ScheduledTaskAction { param($Execute, $Argument) $Argument }
function Register-ScheduledTask { param($TaskName, $Action, $Trigger, $Principal, $Settings) }
function Remove-ItemProperty { param($Path, $Name, $ErrorAction) }
function Get-UpgradeRegistryValue { param($Name) if ($script:probePasses) { '2026-10-01T11:25:41Z' } }
function Start-Sleep { param($Seconds) $script:probeSleeps++ }
function Set-ScheduledTask { param($TaskName, $Action, $ErrorAction) $script:restoredAction = $Action }
$script:TaskMonitor = 'OSUpgradePhaseMonitor'
$script:RegRoot = 'Fixture'
$script:LogDir = 'Fixture'
$script:taskMissing = $false
$script:taskState = 'Ready'
$monitorScript = 'C:\fixture\Update-UpgradeStatus.ps1'
$action = 'normal-monitor-action'
$script:probePasses = $true
$script:probeTaskResult = 0
$script:probeSleeps = 0
. $probe
Assert-Equal $monitorReady $true 'SYSTEM preflight requires registry proof of execution'
Assert-Equal $script:restoredAction $action 'Successful preflight restores the normal monitor action'
$script:probePasses = $false
$script:restoredAction = $null
$script:probeSleeps = 0
$threw = $false
try { . $probe } catch { $threw = $_.Exception.Message -match 'Refusing to launch Setup without tracking' }
Assert-Equal $threw $true 'Unresponsive monitor fails closed before Setup'
Assert-Equal $script:probeSleeps 30 'Monitor preflight timeout is bounded at thirty one-second waits'
Assert-Equal $script:restoredAction $null 'Failed preflight cannot hand off to the normal monitor'
$script:probePasses = $true
$script:probeTaskResult = 5
$threw = $false
try { . $probe } catch { $threw = $_.Exception.Message -match 'LastTaskResult=5' }
Assert-Equal $threw $true 'A marker written before a failing probe exit cannot authorize Setup'

Write-Host "PASS: $script:assertions isolated monitoring/progress assertions; no server operations were performed."
