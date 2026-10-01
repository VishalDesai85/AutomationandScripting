$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path -Parent $PSScriptRoot) 'ServerA-Orchestrator\Start-RemoteUpgradeOrchestrator.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors -join "`n") }
$passed = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}
foreach ($name in @('Get-RemoteOperatingSystem', 'Get-RemoteStatusViaWinRM', 'Get-UpgradeStatus', 'Get-RemoteStatusViaCimDcom')) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}

# Only bind parameters: never execute the operational script.
$bind = [scriptblock]::Create("[CmdletBinding()]`n" + $ast.ParamBlock.Extent.Text + "`n`$true")
foreach ($entry in @(
    @{ PollIntervalSeconds = 0 }, @{ FastPollIntervalSeconds = -1 },
    @{ TimeoutMinutes = 0 }, @{ RetentionDays = 0 },
    @{ StatusJsonPath = '\\server\share\status.json' },
    @{ RemoteStagingPath = 'relative' }, @{ TargetComputer = '..\escape' }
)) {
    $argsMap = @{ TargetComputer = 'TestVM'; SourceFilesPath = 'C:\fixtures' }
    foreach ($key in $entry.Keys) { $argsMap[$key] = $entry[$key] }
    $rejected = $false
    try { & $bind @argsMap | Out-Null } catch { $rejected = $true }
    Assert-True $rejected "Invalid parameters rejected: $($entry.Keys -join ', ')"
}
Assert-True (& $bind -TargetComputer TestVM -SourceFilesPath C:\fixtures -MonitorOnly -PollIntervalSeconds 1) 'Fast monitor-only parameters bind'
Assert-True (& $bind -TargetComputer TestVM -SourceFilesPath C:\fixtures -PrecheckOnly) 'Assessment-only parameters bind'

function Write-Log { param($Message, $Level) }
function New-CimSessionOption {
    param([switch]$UseSsl, [switch]$SkipCACheck, [switch]$SkipCNCheck, [switch]$SkipRevocationCheck, $Protocol)
    $script:options = $PSBoundParameters
    return 'mock-options'
}
function New-CimSession {
    param($ComputerName, $Credential, $Port, $SessionOption, $OperationTimeoutSec, $ErrorAction)
    $script:sessionArgs = $PSBoundParameters
    return 'mock-session'
}
function Get-CimInstance {
    param($CimSession, $ClassName, $OperationTimeoutSec, $ErrorAction)
    if ($script:failCim) { throw 'simulated CIM failure' }
    [pscustomobject]@{ BuildNumber = '20348' }
}
function Remove-CimSession { param($CimSession, $ErrorAction) $script:removed++ }
$TargetComputer = 'TestVM'
$Credential = [pscredential]::new('fixture', (ConvertTo-SecureString 'not-a-real-password' -AsPlainText -Force))
$script:failCim = $false
foreach ($transport in @('Http', 'Https', 'HttpsSkipCert')) {
    $script:WinRMTransport = $transport
    $script:removed = 0
    $os = Get-RemoteOperatingSystem
    Assert-True ($os.BuildNumber -eq '20348') "$transport returns live build"
    Assert-True ($script:sessionArgs.Credential -eq $Credential) "$transport credentials supplied to session, not Get-CimInstance"
    Assert-True ($script:removed -eq 1) "$transport session disposed"
    Assert-True ([bool]$script:options.UseSsl -eq ($transport -ne 'Http')) "$transport TLS selection"
    Assert-True ([bool]$script:options.SkipCACheck -eq ($transport -eq 'HttpsSkipCert')) "$transport certificate bypass is explicit"
}
$Credential = $null
$script:removed = 0
$script:failCim = $true
$threw = $false
try { Get-RemoteOperatingSystem | Out-Null } catch { $threw = $true }
Assert-True ($threw -and $script:removed -eq 1) 'Failed live query propagates and disposes session'
Assert-True (-not $script:sessionArgs.ContainsKey('Credential')) 'Integrated authentication does not bind null credentials'

function Get-WinRMSessionParams { @{ ComputerName = 'TestVM' } }
function Invoke-Command { param($ComputerName, [switch]$AsJob, $ScriptBlock, $ArgumentList) 'mock-job' }
function Wait-Job { param($Job, $Timeout) if (-not $script:jobTimeout) { $Job } }
function Receive-Job { param($Job, $ErrorAction) $script:jobResult }
function Stop-Job { param($Job, $ErrorAction) }
function Remove-Job { param($Job, [switch]$Force, $ErrorAction) $script:jobRemoved++ }
$script:jobTimeout = $false
$script:jobRemoved = 0
$script:jobResult = [pscustomobject]@{ Phase = 3; Status = 'InProgress' }
$detail = $null
$result = Get-RemoteStatusViaWinRM -JsonPath 'D:\status.json' -ErrorDetail ([ref]$detail)
Assert-True ($result.Phase -eq 3 -and $script:jobRemoved -eq 1) 'WinRM status read returns target data and cleans job'
$script:jobTimeout = $true
$result = Get-RemoteStatusViaWinRM -JsonPath 'D:\status.json' -ErrorDetail ([ref]$detail)
Assert-True ($null -eq $result -and $detail -match 'timed out' -and $script:jobRemoved -eq 2) 'WinRM status timeout is bounded, diagnosed and cleaned'
$script:jobTimeout = $false
$script:jobResult = [pscustomobject]@{ Phase = $null; Status = $null }
$result = Get-RemoteStatusViaWinRM -JsonPath 'D:\status.json' -ErrorDetail ([ref]$detail)
Assert-True ($null -eq $result -and $detail -match 'no complete') 'Empty WinRM payload rejected'

$script:probePing = $false
$script:probeWinRm = $true
function Test-Connection { param($ComputerName, $Count, [switch]$Quiet, $ErrorAction) $script:probePing }
function Test-RemoteWinRM { param($ComputerName, $Cred, $TimeoutSec) $script:probeWinRm }
$script:fileReads = 0
function Read-RemoteFileWithTimeout { param($Path, $TimeoutSec, [ref]$ErrorDetail) $script:fileReads++; '{"unexpected":"payload"}' }
function Invoke-CimMethod { param($CimSession, $Namespace, $ClassName, $MethodName, $Arguments) [pscustomobject]@{ ReturnValue = 2 } }
$script:jobResult = [pscustomobject]@{ Phase = 3; Status = 'InProgress' }
$result = Get-UpgradeStatus -ComputerName TestVM -JsonPath 'D:\status.json'
Assert-True ($result.Source -eq 'WinRM' -and $result.Mode -eq 'ActivePolling' -and -not $result.PingOk) 'Blocked ICMP/SMB/DCOM still permits authenticated WinRM status'
Assert-True ($script:fileReads -eq 0) 'Available authenticated WinRM avoids blocking on admin-share timeouts first'
$script:jobResult = $null
foreach ($probe in @(
    @{ Ping = $false; WinRm = $true; Mode = 'ActivePolling' },
    @{ Ping = $true; WinRm = $false; Mode = 'Heartbeat' },
    @{ Ping = $false; WinRm = $false; Mode = 'Offline' }
)) {
    $script:probePing = $probe.Ping
    $script:probeWinRm = $probe.WinRm
    $result = Get-UpgradeStatus -ComputerName TestVM -JsonPath 'D:\status.json'
    Assert-True ($result.Mode -eq $probe.Mode -and $result.Status -eq 'Unknown' -and $null -eq $result.Stage) "No fabricated progress when status unavailable ($($probe.Mode))"
}

$completion = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.Clauses[0].Item1.Extent.Text -like '*$status.Status -in @("Completed","CompletedWithWarnings")*ActivePolling*'
}, $true)
if (-not $completion) { throw 'Completion decision block not found.' }
$decision = [scriptblock]::Create($completion.Extent.Text)
function Get-RemoteOperatingSystem {
    if ($script:failCim) { throw 'simulated unavailable build' }
    [pscustomobject]@{ BuildNumber = '20348' }
}
foreach ($case in @(
    @{ Expected = '20348'; QueryFails = $false; Outcome = 'Completed' },
    @{ Expected = '17763'; QueryFails = $false; Outcome = 'Timeout' },
    @{ Expected = $null; QueryFails = $false; Outcome = 'Timeout' },
    @{ Expected = '20348'; QueryFails = $true; Outcome = 'Timeout' }
)) {
    $actual = & {
        $status = [pscustomobject]@{ Status = 'Completed'; Mode = 'ActivePolling' }
        $targetBuildKnown = $case.Expected
        $script:failCim = $case.QueryFails
        $buildConfirmFailCount = 8
        $finalOutcome = 'Timeout'
        while ($true) { . $decision; break }
        $finalOutcome
    }
    Assert-True ($actual -eq $case.Outcome) "Completion requires matching live build (expected=$($case.Expected), queryFails=$($case.QueryFails))"
}
$percentage = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.Clauses[0].Item1.Extent.Text -eq '$null -ne $status.PercentComplete'
}, $true)
if (-not $percentage) { throw 'Percentage decision block not found.' }
$updatePercentage = [scriptblock]::Create($percentage.Extent.Text)
$lastKnownPercent = 100
$lastKnownPercentSource = 'Measured'
$lastKnownStage = 'Stage 1/3'
$status = [pscustomobject]@{ Status = 'InProgress'; PercentComplete = 0; PercentSource = 'Measured'; Stage = 'Stage 2/3' }
. $updatePercentage
Assert-True ($lastKnownPercent -eq 0 -and $lastKnownStage -eq 'Stage 2/3') 'New stage does not inherit preceding stage 100 percent'
$lastKnownPercent = 40
$status.PercentComplete = 10
. $updatePercentage
Assert-True ($lastKnownPercent -eq 40) 'Within-stage progress remains monotonic'
$status.PercentComplete = $null
. $updatePercentage
Assert-True ($lastKnownPercent -eq 40 -and $pctSourceForDisplay -match 'cached') 'Unavailable progress remains explicitly cached'
$status.Status = 'Failed'
$status.PercentComplete = 0
. $updatePercentage
Assert-True ($lastKnownPercent -eq 0) 'Terminal failure is not hidden by monotonic clamp'
$status.Status = 'InProgress'
$status.Stage = 'Stage 3/3'
$status.PercentComplete = $null
$lastKnownPercent = 100
$lastKnownStage = 'Stage 2/3'
. $updatePercentage
Assert-True ($null -eq $lastKnownPercent -and $pctSourceForDisplay -eq 'no verified sample') 'New Setup stage cannot carry forward backup completion while its percentage is unknown'

$targetPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'ServerB-Target\Start-TargetUpgrade.ps1'
$targetTokens = $null
$targetParseErrors = $null
$targetAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $targetPath, [ref]$targetTokens, [ref]$targetParseErrors)
if ($targetParseErrors.Count) { throw ($targetParseErrors -join "`n") }
$targetText = $targetAst.Extent.Text
$orchestratorText = $ast.Extent.Text
$targetParameterNames = @($targetAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
Assert-True ($targetParameterNames -contains 'PrecheckOnly') 'Target starter exposes PrecheckOnly'
Assert-True ($targetText -notmatch 'reg\.exe add.+/v Phase') 'Event 1074 watcher cannot bypass phase/terminal guards with direct registry writes'
Assert-True ($targetText -match 'monitorScript.+-RebootEvent') 'Event 1074 watcher mirrors its evidence through the shared JSON writer'
Assert-True ($targetText -match 'New-ScheduledTaskTrigger -AtStartup') 'Target monitor runs at startup, not only on the repetition clock'
Assert-True ($targetText -match 'Refusing to launch Setup without tracking') 'SYSTEM monitor health is required before Setup kickoff'
Assert-True ($targetText -match '(?s)StarterMutex\.ReleaseMutex\(\).+Start-ScheduledTask -TaskName \$script:TaskMonitor') 'First normal monitor invocation occurs after starter lock release'
Assert-True ($targetText -match '(?s)StarterMutex\.ReleaseMutex\(\).+Start-ScheduledTask -TaskName \$script:TaskMonitor.+if \(\$UseControlledReboot\)') 'Controlled-reboot waiting cannot hold the starter lock and starve Downlevel monitoring'
Assert-True ($orchestratorText -match 'ProgressFreshness, ProgressUpdatedAtUtc, ProgressHighWaterPercent') 'WinRM status projection includes progress evidence metadata'
Assert-True ($orchestratorText -match 'ExpectedDisconnect\s*=\s*Get-UpgradeRegDWord') 'DCOM status projection includes expected-disconnect evidence'
Assert-True ($orchestratorText -match 'expected reboot disconnect after Event ID 1074') 'Connectivity-gap display distinguishes an expected reboot'
$targetWriteLog = $targetAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Write-Log'
}, $true)
$levelParameter = $targetWriteLog.Body.ParamBlock.Parameters |
    Where-Object { $_.Name.VariablePath.UserPath -eq 'Level' }
$validateSet = $levelParameter.Attributes |
    Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
$allowedTargetLogLevels = @($validateSet.PositionalArguments |
    ForEach-Object { $_.SafeGetValue() })
$unsupportedTargetLogLevels = @(
    $targetAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Write-Log' -and
        $node.CommandElements.Count -ge 3 -and
        $node.CommandElements[2] -is [System.Management.Automation.Language.StringConstantExpressionAst]
    }, $true) |
        ForEach-Object { $_.CommandElements[2].Value } |
        Where-Object { $_ -notin $allowedTargetLogLevels } |
        Sort-Object -Unique
)
Assert-True ($unsupportedTargetLogLevels.Count -eq 0) "All literal target log levels are accepted by Write-Log: $($unsupportedTargetLogLevels -join ', ')"
$orchestratorParameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
Assert-True ($orchestratorParameterNames -contains 'SkipDismScanHealthLab') 'Orchestrator exposes lab-only DISM skip'
$remoteArgsAssignment = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$remoteArgs'
}, $true)
Assert-True ($remoteArgsAssignment.Extent.Text -match 'SkipDismScanHealthLab\s*=\s*\[bool\]\$SkipDismScanHealthLab') 'Orchestrator marshals DISM skip to target as Boolean'
Assert-True ($targetParameterNames -contains 'SkipDismScanHealthLab') 'Target starter exposes lab-only DISM skip'
$skipDismBranch = $targetAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.Clauses[0].Item1.Extent.Text -eq '$SkipDismScanHealthLab' -and
    $node.Extent.Text -match 'Component store health \(DISM ScanHealth\)'
}, $true)
Assert-True ($null -ne $skipDismBranch) 'Target has an explicit DISM skip branch'
$skipDismBody = $skipDismBranch.Clauses[0].Item2.Extent.Text
Assert-True ($skipDismBody -match '-Result\s+"WARN"' -and
    $skipDismBody -match 'NOT validated' -and
    $skipDismBody -notmatch 'Dism\.exe' -and
    $skipDismBody -notmatch 'SFC /scannow still runs') 'DISM skip records an unvalidated warning without making assumptions about SFC'
Assert-True ($skipDismBranch.ElseClause.Extent.Text -match 'Dism\.exe.+/ScanHealth') 'Normal path still runs DISM ScanHealth'
Assert-True ($orchestratorParameterNames -contains 'SkipSfcScanNowLab') 'Orchestrator exposes lab-only SFC skip'
Assert-True ($remoteArgsAssignment.Extent.Text -match 'SkipSfcScanNowLab\s*=\s*\[bool\]\$SkipSfcScanNowLab') 'Orchestrator marshals SFC skip to target as Boolean'
Assert-True ($targetParameterNames -contains 'SkipSfcScanNowLab') 'Target starter exposes lab-only SFC skip'
$skipSfcBranch = $targetAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.Clauses[0].Item1.Extent.Text -eq '$SkipSfcScanNowLab' -and
    $node.Extent.Text -match 'System file integrity \(SFC /scannow\)'
}, $true)
Assert-True ($null -ne $skipSfcBranch) 'Target has an explicit SFC skip branch'
$skipSfcBody = $skipSfcBranch.Clauses[0].Item2.Extent.Text
Assert-True ($skipSfcBody -match '-Result\s+"WARN"' -and
    $skipSfcBody -match 'NOT validated' -and
    $skipSfcBody -notmatch 'sfc\.exe' -and
    $skipSfcBody -match 'CBS\.log was not analyzed') 'SFC skip records an unvalidated warning without invoking SFC'
Assert-True ($skipSfcBranch.ElseClause.Extent.Text -match 'sfc\.exe\s+/scannow') 'Normal path still runs SFC scannow'
$assessmentBranch = $targetAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text -match 'if \(\$PrecheckOnly\)' -and
    $node.Extent.Text -match 'AssessmentPassed'
}, $true)
Assert-True ($null -ne $assessmentBranch) 'PrecheckOnly publishes a distinct AssessmentPassed state'
Assert-True ($assessmentBranch.Extent.Text -match '\breturn\b') 'PrecheckOnly returns before backup and Setup'
Assert-True ($assessmentBranch.Extent.Text -notmatch '-Status\s+"Completed"') 'Assessment is not confused with completed OS upgrade'
Assert-True ($assessmentBranch.Extent.Text -match '-PercentSource\s+"Measured"') 'Completed assessment retains measured task-count provenance'
Assert-True ($targetText -match [regex]::Escape('Global\OSUpgradeAutomation.StartTargetUpgrade')) 'Target starter uses the shared concurrency mutex'
Assert-True ($targetText -match 'computerinfo\.txt' -and $targetText -match 'systeminfo\.txt' -and $targetText -match 'ipconfig\.txt') 'Backup captures required host diagnostics'
Assert-True ($targetText -match 'Required system state backup failed - refusing to launch Windows Setup') 'Required system-state backup fails closed'
Assert-True ($targetText -match 'setup\.exe was not observed within 60 seconds.*Treating kickoff as failed') 'Unconfirmed Setup launch fails closed'
$retryFlagsAssignment = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$reRunFlags'
}, $true)
Assert-True ($retryFlagsAssignment.Extent.Text.Contains('$k -eq ''Credential''') -and
    $retryFlagsAssignment.Extent.Text.Contains('-Credential `$cred')) 'Retry command preserves the credential placeholder by parameter name'
Assert-True ($ast.Extent.Text -notmatch 'Nothing was changed.+no backup, no ISO mount') 'Failure guidance does not deny assessment side effects'
Assert-True ($ast.Extent.Text -match '\$preCheckReportHint\s*=\s*Join-Path\s+\$BackupRoot\s+"PreCheckReport_\*\.log"') 'Failure guidance derives the actual precheck report path'
Assert-True ($ast.Extent.Text -match '(?s)\$received\s*=\s*Receive-Job\s+-Job\s+\$remoteJob.+?if\s*\(\$received\).+?Write-Progress\s+-Id\s+\$stage12ProgressId.+?-Completed') 'Stage progress is cleared after the final remote stream drain'
Write-Host "Orchestrator tests passed: $passed"
