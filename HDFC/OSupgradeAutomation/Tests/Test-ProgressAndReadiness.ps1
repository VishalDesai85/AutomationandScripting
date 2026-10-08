[CmdletBinding()]
param([string]$SetupLogPath = "")

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$syntaxTrees = @{}
foreach ($file in Get-ChildItem $projectRoot -Filter '*.ps1' -Recurse) {
    $tokens = $null
    $parseErrors = $null
    $syntaxTrees[$file.Name] = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "$($file.Name): $($parseErrors.Message -join '; ')" }
}

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-TestFunction {
    param($Tree, [string]$Name)
    $definition = $Tree.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)
    if (-not $definition) { throw "Function not found: $Name" }
    [scriptblock]::Create($definition.Extent.Text)
}

function New-TestMutex {
    $mutex = [pscustomobject]@{}
    $mutex | Add-Member ScriptMethod WaitOne { param($Milliseconds) return $true }
    $mutex | Add-Member ScriptMethod ReleaseMutex {}
    $mutex | Add-Member ScriptMethod Dispose {}
    return $mutex
}

& {
    $tree = $syntaxTrees['Start-RemoteUpgradeOrchestrator.ps1']
    $initialization = $tree.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.IfStatementAst] -and
        $_.Extent.Text.StartsWith('if ([string]::IsNullOrWhiteSpace($SourceFilesPath))')
    } | Select-Object -First 1
    Assert-Condition ($null -ne $initialization) 'Source directory must be resolved after parameter binding'
    $probeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('OSUpgradeStartup_' + [guid]::NewGuid().ToString('N'))
    $probeDirectory = Join-Path $probeRoot 'ServerA-Orchestrator'
    $probePath = Join-Path $probeDirectory 'StartupProbe.ps1'
    try {
        [System.IO.Directory]::CreateDirectory($probeDirectory) | Out-Null
        $probe = $tree.ParamBlock.Extent.Text + [Environment]::NewLine +
            '$ErrorActionPreference = "Stop"' + [Environment]::NewLine +
            $initialization.Extent.Text + [Environment]::NewLine +
            '$SourceFilesPath | ConvertTo-Json -Compress'
        [System.IO.File]::WriteAllText($probePath, $probe)
        $expected = Join-Path $probeRoot 'ServerB-Target'
        $powershellPath = Join-Path $PSHOME 'powershell.exe'
        $actual = & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $probePath -TargetComputer 'offline-test'
        Assert-Condition ($LASTEXITCODE -eq 0 -and ($actual | ConvertFrom-Json) -eq $expected) 'Default source directory failed under powershell.exe -File'
        $explicit = Join-Path $probeRoot 'Custom Scripts'
        $actual = & $powershellPath -NoProfile -ExecutionPolicy Bypass -File $probePath -TargetComputer 'offline-test' -SourceFilesPath $explicit
        Assert-Condition ($LASTEXITCODE -eq 0 -and ($actual | ConvertFrom-Json) -eq $explicit) 'Explicit source directory was not preserved'
        'PASS: powershell.exe -File startup default and explicit source paths (startup-only extracted code)'
    } finally {
        if ([System.IO.Directory]::Exists($probeRoot)) { [System.IO.Directory]::Delete($probeRoot, $true) }
    }
}

& {
    . (Get-TestFunction $syntaxTrees['OSUpgradeStatus.ps1'] 'Get-UpgradePendingRebootState')
    $fixture = @{ Queue = $null; PendingKey = ''; RegistryFailure = $false }
    function Test-Path { param($Path, $ErrorAction) return ($Path -eq $fixture.PendingKey) }
    function Get-ItemProperty {
        param($Path, $ErrorAction)
        if ($fixture.RegistryFailure) { throw 'Access denied' }
        [pscustomobject]@{ PendingFileRenameOperations = $fixture.Queue }
    }
    foreach ($case in @(
        @{ Queue = $null; Pending = $false; Actions = '' },
        @{ Queue = @('', ''); Pending = $false; Actions = '' },
        @{ Queue = @('\??\C:\old.dll', '\??\C:\new.dll'); Pending = $true; Actions = 'RenameOrReplace' },
        @{ Queue = @('\??\C:\old.tmp', ''); Pending = $true; Actions = 'Delete' },
        @{ Queue = @('', '\??\C:\new.dll'); Pending = $true; Actions = 'InvalidEntry' },
        @{ Queue = @('\??\C:\old.tmp'); Pending = $true; Actions = 'Delete' },
        @{ Queue = @('\??\C:\old.tmp', '', '\??\C:\old.dll', '\??\C:\new.dll'); Pending = $true; Actions = 'Delete,RenameOrReplace' }
    )) {
        $fixture.Queue = $case.Queue
        $result = Get-UpgradePendingRebootState
        Assert-Condition ($result.RebootPending -eq $case.Pending) 'Wrong reboot gate decision'
        Assert-Condition ($result.UpgradeBlocked -eq $case.Pending) 'Default reboot gate must retain every blocker'
        Assert-Condition (($result.Operations.Action -join ',') -eq $case.Actions) 'Wrong operation parsing'
        $bypassed = Get-UpgradePendingRebootState -SkipPendingFileRenameCheck
        Assert-Condition ($bypassed.RebootPending -eq $case.Pending -and -not $bypassed.UpgradeBlocked) 'Rename bypass must preserve observed state while removing only that blocker'
        Assert-Condition ($bypassed.PendingFileRenameCheckSkipped -and ($bypassed.Operations.Action -join ',') -eq $case.Actions) 'Bypass lost queued-operation diagnostics'
        Assert-Condition ($bypassed.BlockingReasons.Count -eq 0) 'Rename bypass left a queue-only blocker'
    }
    $fixture.Queue = $null
    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )) {
        $fixture.PendingKey = $key
        Assert-Condition (Get-UpgradePendingRebootState).RebootPending 'Servicing gate lost'
        $fixture.Queue = @('\??\C:\old.tmp', '')
        $bypassed = Get-UpgradePendingRebootState -SkipPendingFileRenameCheck
        Assert-Condition ($bypassed.UpgradeBlocked -and $bypassed.BlockingReasons.Count -eq 1 -and $bypassed.Reasons.Count -eq 2) 'Rename bypass must never suppress CBS or Windows Update blockers'
    }
    $fixture.RegistryFailure = $true
    $failed = $false
    try { Get-UpgradePendingRebootState | Out-Null } catch { $failed = $true }
    Assert-Condition $failed 'Unreadable registry must fail closed'
    $failed = $false
    try { Get-UpgradePendingRebootState -SkipPendingFileRenameCheck | Out-Null } catch { $failed = $true }
    Assert-Condition $failed 'Rename bypass must not suppress registry-query failures'
    'PASS: pending reboot parsing and safety gates'
}

& {
    $tree = $syntaxTrees['Start-RemoteUpgradeOrchestrator.ps1']
    $loop = $tree.Find({
        param($node)
        $node -is [System.Management.Automation.Language.WhileStatementAst] -and
        $node.Condition.Extent.Text -eq '$remoteJob.State -eq ''Running'''
    }, $true)
    Assert-Condition ($null -ne $loop) 'Kickoff loop not found'
    $reader = $tree.FindAll({param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-RemoteStatusJsonViaWinRM'
    }, $true)
    Assert-Condition ($reader.Count -eq 1 -and $reader[0].Extent.StartOffset -lt $loop.Extent.StartOffset) 'WinRM reader must be defined once, before kickoff'
    $fixture = @{ SMB = $null; WinRM = $null; Reads = 0; Displayed = $null; Banner = ''; Observation = $null }
    function Receive-Job { $remoteJob.State = 'Completed' }
    function Read-RemoteFileWithTimeout { return $fixture.SMB }
    function Read-RemoteStatusJsonViaWinRM { $fixture.Reads++; return $fixture.WinRM }
    function Write-LocalStatusMirror { param($ProducerStatus, $ObservationStatus, $ObservationError) $fixture.Observation = $ObservationStatus }
    function Write-Progress { param($Activity, $Status, $PercentComplete) $fixture.Displayed = $PercentComplete; $fixture.Banner = $Status }
    function Write-Log { param($Message, $Level) }
    function Start-Sleep { param($Seconds) }
    $TargetComputer = 'mock-target'
    $StatusJsonPath = 'D:\upgrade_status.json'
    $stage12UncPath = '\\mock-target\D$\upgrade_status.json'
    $spinnerChars = @('|', '/', '-', '\')
    $stage12Start = Get-Date
    $TimeoutMinutes = 180
    $stage12Pct = $null
    $stage12StagePct = $null
    $stage12PhaseName = $null
    $stage12ReadWarningLogged = $false
    $allReceived = @()
    foreach ($sample in @(
        @{ Raw = $null; Expected = $null; Text = 'Awaiting target status' },
        @{ Raw = '{"Phase":1,"PercentComplete":2,"StagePercentComplete":29,"PhaseName":"Prechecks"}'; Expected = 2; Text = 'Overall 2%; stage 29%' },
        @{ Raw = '{"Phase":2,"PercentComplete":17,"StagePercentComplete":50,"PhaseName":"Backup"}'; Expected = 17; Text = 'Overall 17%; stage 50%' },
        @{ Raw = 'invalid-json'; Expected = 17; Text = 'cached' },
        @{ Raw = $null; Expected = 17; Text = 'cached' }
    )) {
        $fixture.WinRM = $sample.Raw
        $spinnerIdx = 0
        $remoteJob = [pscustomobject]@{ State = 'Running' }
        . ([scriptblock]::Create($loop.Extent.Text))
        Assert-Condition ($fixture.Displayed -eq $sample.Expected) 'Wrong banner percentage'
        Assert-Condition ($fixture.Banner.Contains($sample.Text)) 'Wrong banner stage/cache label'
        Assert-Condition ($fixture.Observation.Source -eq "WinRM($StatusJsonPath)") 'Wrong fallback source'
    }
    $previousReads = $fixture.Reads
    $fixture.SMB = '{"Phase":2,"PercentComplete":25,"PhaseName":"Backup"}'
    $spinnerIdx = 0
    $remoteJob = [pscustomobject]@{ State = 'Running' }
    . ([scriptblock]::Create($loop.Extent.Text))
    Assert-Condition ($fixture.Reads -eq $previousReads -and $fixture.Displayed -eq 25) 'SMB success should not use fallback'
    'PASS: kickoff WinRM fallback, stage display, cache, missing status, SMB success'
}

& {
    $tree = $syntaxTrees['Start-RemoteUpgradeOrchestrator.ps1']
    $probeDefinition = $tree.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left.Extent.Text -eq '$script:WinRMProbeScript'
    } | Select-Object -First 1
    Assert-Condition ($null -ne $probeDefinition) 'WinRM probe definition is missing'
    . ([scriptblock]::Create($probeDefinition.Extent.Text))
    foreach ($name in @('Get-WinRMSessionParams','Test-WinRMTransport','Test-RemoteWinRM','Resolve-WinRMTransport','Get-WinRMTransportLabel')) {
        . (Get-TestFunction $tree $name)
    }
    $fixture = @{ Last = $null; RemovedSessions = 0; Ports = @(); BlockHttp = $false }
    function Test-WSMan {
        param($ComputerName, $Credential, $Authentication, $Port, [switch]$UseSSL, $ErrorAction)
        $fixture.Last = $PSBoundParameters
        $fixture.Ports += $Port
        if ($Credential -and $Authentication -ne 'Negotiate') { throw 'Explicit credentials require Negotiate in this customer configuration' }
        if ($fixture.BlockHttp -and $Port -eq 5985) { throw 'HTTP blocked' }
        return 'WSMan response'
    }
    function New-PSSession {
        param($ComputerName, $Credential, $Authentication, $Port, [switch]$UseSSL, $SessionOption, $ErrorAction)
        $fixture.Last = $PSBoundParameters
        if ($Credential -and $Authentication -ne 'Negotiate') { throw 'Explicit credentials require Negotiate in this customer configuration' }
        return 'test-session'
    }
    function New-PSSessionOption { param([switch]$SkipCACheck, [switch]$SkipCNCheck, [switch]$SkipRevocationCheck) return 'SkipChecks' }
    function Remove-PSSession { param($Session, $ErrorAction) $fixture.RemovedSessions++ }
    function Start-Job { param($ScriptBlock, [object[]]$ArgumentList) [pscustomobject]@{ Output = (& $ScriptBlock @ArgumentList) } }
    function Wait-Job { param($Job, $Timeout) return $Job }
    function Receive-Job { param($Job, $ErrorAction) return $Job.Output }
    function Stop-Job { param($Job, $ErrorAction) }
    function Remove-Job { param($Job, [switch]$Force, $ErrorAction) }
    function Write-Log { param($Message, $Level) }
    $testCredential = [pscredential]::new('test-user', (ConvertTo-SecureString 'test-placeholder' -AsPlainText -Force))
    $TargetComputer = 'mock-target'
    $failedWithoutNegotiate = $false
    try { Test-WSMan -ComputerName $TargetComputer -Credential $testCredential -Port 5985 | Out-Null }
    catch { $failedWithoutNegotiate = $true }
    Assert-Condition $failedWithoutNegotiate 'Customer authentication requirement was not reproduced by the mock'
    foreach ($withCredential in @($false, $true)) {
        $Credential = if ($withCredential) { $testCredential } else { $null }
        foreach ($transport in @('Http','Https','HttpsSkipCert')) {
            $script:WinRMTransport = $transport
            $connected = Test-RemoteWinRM -ComputerName $TargetComputer -Cred $Credential
            Assert-Condition $connected "Negotiate-enabled recurring probe failed for $transport, explicit credentials=$withCredential"
            Assert-Condition ($fixture.Last.Credential -eq $Credential -and $fixture.Last.ComputerName -eq $TargetComputer) 'Probe lost target or credentials'
            Assert-Condition ($fixture.Last.ContainsKey('Authentication') -eq $withCredential) 'Probe must preserve default authentication when no credentials were supplied'
            if ($withCredential) { Assert-Condition ($fixture.Last.Authentication -eq 'Negotiate') 'Probe did not explicitly select Negotiate' }
            Assert-Condition ($fixture.Last.Port -eq $(if ($transport -eq 'Http') { 5985 } else { 5986 })) 'Probe changed the transport port'
            Assert-Condition (($fixture.Last.SessionOption -eq 'SkipChecks') -eq ($transport -eq 'HttpsSkipCert')) 'Probe bypassed certificate validation without the explicit mode'

            $sessionParams = Get-WinRMSessionParams
            Assert-Condition ($sessionParams.ComputerName -eq $TargetComputer -and $sessionParams.Credential -eq $Credential) 'Resume/staging session builder lost connection identity'
            Assert-Condition ($sessionParams.ContainsKey('Authentication') -eq $withCredential) 'Session builder changed implicit authentication'
            if ($withCredential) { Assert-Condition ($sessionParams.Authentication -eq 'Negotiate') 'Resume/staging session must use Negotiate with credentials' }
            Assert-Condition ([bool]$sessionParams.UseSSL -eq ($transport -ne 'Http')) 'Session builder changed HTTP/HTTPS selection'
            Assert-Condition (($sessionParams.SessionOption -eq 'SkipChecks') -eq ($transport -eq 'HttpsSkipCert')) 'Session builder changed certificate validation'
        }
    }
    Assert-Condition ($fixture.RemovedSessions -eq 2) 'HTTPS certificate-bypass probes must dispose their temporary sessions'
    $fixture.BlockHttp = $true; $fixture.Ports = @()
    $UseSSL = $false; $SkipCertificateCheck = $false
    $resolved = Resolve-WinRMTransport -ComputerName $TargetComputer -Cred $testCredential
    Assert-Condition ($resolved -eq 'Https' -and ($fixture.Ports -join ',') -eq '5985,5986' -and $fixture.Last.Authentication -eq 'Negotiate') 'Authenticated HTTP-to-HTTPS fallback regressed'
    $fixture.Ports = @(); $UseSSL = $true
    $resolved = Resolve-WinRMTransport -ComputerName $TargetComputer -Cred $testCredential
    Assert-Condition ($resolved -eq 'Https' -and ($fixture.Ports -join ',') -eq '5986') 'UseSSL must not attempt HTTP'
    $script:WinRMTransport = $null
    'PASS: customer Negotiate requirement, initial/recurring probes, session builder, integrated-auth preservation, and HTTPS fallback (mocked)'
}

& {
    . (Get-TestFunction $syntaxTrees['Start-RemoteUpgradeOrchestrator.ps1'] 'Read-RemoteStatusJsonViaWinRM')
    $fixture = @{ Invoke = $null; TimedOut = $false; Removed = 0 }
    function Invoke-Command {
        param($ComputerName, $Credential, $Authentication, [switch]$UseSSL, $Port, $SessionOption, $ScriptBlock, $ArgumentList, $ErrorAction)
        $fixture.Invoke = $PSBoundParameters
        if ($Credential -and $Authentication -ne 'Negotiate') { throw 'Explicit credentials require Negotiate' }
        return '{"Phase":1,"PercentComplete":2}'
    }
    function New-PSSessionOption { param([switch]$SkipCACheck, [switch]$SkipCNCheck, [switch]$SkipRevocationCheck) return 'SkipChecks' }
    function Start-Job { param($ScriptBlock, $ArgumentList) [pscustomobject]@{ Output = (& $ScriptBlock @ArgumentList) } }
    function Wait-Job { param($Job, $Timeout) if (-not $fixture.TimedOut) { return $Job } }
    function Receive-Job { param($Job, $ErrorVariable, $ErrorAction) return $Job.Output }
    function Stop-Job { param($Job, $ErrorAction) }
    function Remove-Job { param($Job, [switch]$Force, $ErrorAction) $fixture.Removed++ }
    $credential = [pscredential]::new('test-user', (ConvertTo-SecureString 'test-placeholder' -AsPlainText -Force))
    foreach ($withCredential in @($false, $true)) {
      $selectedCredential = if ($withCredential) { $credential } else { $null }
      foreach ($transport in @('Http', 'Https', 'HttpsSkipCert')) {
        $detail = $null
        $raw = Read-RemoteStatusJsonViaWinRM -ComputerName 'mock-target' -Cred $selectedCredential -JsonPath 'D:\upgrade_status.json' -Transport $transport -ErrorDetail ([ref]$detail)
        Assert-Condition (($raw | ConvertFrom-Json).PercentComplete -eq 2) 'JSON reader lost data'
        Assert-Condition ($fixture.Invoke.Credential -eq $selectedCredential -and $fixture.Invoke.ComputerName -eq 'mock-target') 'Wrong connection identity'
        Assert-Condition ($fixture.Invoke.ContainsKey('Authentication') -eq $withCredential) 'JSON reader changed implicit authentication'
        if ($withCredential) { Assert-Condition ($fixture.Invoke.Authentication -eq 'Negotiate') 'JSON reader must use Negotiate with credentials' }
        Assert-Condition ($fixture.Invoke.ArgumentList -eq 'D:\upgrade_status.json') 'Wrong remote path'
        Assert-Condition ([bool]$fixture.Invoke.UseSSL -eq ($transport -ne 'Http')) 'Wrong SSL setting'
        if ($transport -ne 'Http') { Assert-Condition ($fixture.Invoke.Port -eq 5986) 'Wrong HTTPS port' }
        Assert-Condition (($fixture.Invoke.SessionOption -eq 'SkipChecks') -eq ($transport -eq 'HttpsSkipCert')) 'Certificate checks changed unexpectedly'
      }
    }
    $fixture.TimedOut = $true
    $raw = Read-RemoteStatusJsonViaWinRM -ComputerName 'mock-target' -JsonPath 'D:\upgrade_status.json' -Transport Http -ErrorDetail ([ref]$detail)
    Assert-Condition ($null -eq $raw -and $detail -like 'Timed out*' -and $fixture.Removed -eq 7) 'Timeout/cleanup failed'
    'PASS: WinRM transport, credentials, path, timeout and cleanup (mocked)'
}

& {
    $fixture = @{ Queue = @('\??\C:\installer.tmp', ''); Warning = ''; Connection = $null; PendingKey = '' }
    function Test-Path { param($Path, $ErrorAction) return ($Path -eq $fixture.PendingKey) }
    function Get-ItemProperty { param($Path, $ErrorAction) [pscustomobject]@{ PendingFileRenameOperations = $fixture.Queue } }
    function Get-CimInstance { param($ClassName, $ErrorAction) [pscustomobject]@{ Caption = 'Test OS'; BuildNumber = '17763'; LastBootUpTime = [datetime]'2026-01-01' } }
    function Invoke-Command {
        param($ComputerName, $Credential, $Authentication, [switch]$UseSSL, $Port, $SessionOption, $ScriptBlock, [object[]]$ArgumentList, $ErrorAction)
        $fixture.Connection = $PSBoundParameters
        if ($Credential -and $Authentication -ne 'Negotiate') { throw 'Explicit credentials require Negotiate' }
        & $ScriptBlock @ArgumentList
    }
    function New-PSSessionOption { param([switch]$SkipCACheck, [switch]$SkipCNCheck, [switch]$SkipRevocationCheck) return 'SkipChecks' }
    function Write-Warning { param($Message) $fixture.Warning = $Message }
    function Write-Host { param($Object) }
    function Out-Host { process {} }
    $readinessPath = Join-Path $projectRoot 'ServerA-Orchestrator\Test-UpgradeReadiness.ps1'
    $result = & $readinessPath -TargetComputer 'mock-target'
    Assert-Condition ($result.RebootPending -and $result.Operations[0].Action -eq 'Delete') 'Readiness lost pending operation'
    Assert-Condition ($fixture.Warning -like '*BLOCKED*' -and $result.Build -eq '17763') 'Readiness summary incorrect'
    Assert-Condition (-not $fixture.Connection.UseSSL) 'HTTP readiness must not force SSL'
    $fixture.Queue = $null
    $fixture.Warning = ''
    $result = & $readinessPath -TargetComputer 'mock-target' -UseSSL
    Assert-Condition (-not $result.RebootPending -and -not $fixture.Warning) 'Clear reboot gate reported blocked'
    Assert-Condition ($fixture.Connection.UseSSL -and $fixture.Connection.Port -eq 5986 -and -not $fixture.Connection.SessionOption) 'HTTPS readiness must verify certificates'
    $fixture.Queue = @('\??\C:\installer.tmp', '')
    $result = & $readinessPath -TargetComputer 'mock-target' -SkipPendingFileRenameCheck
    Assert-Condition ($result.RebootPending -and -not $result.UpgradeBlocked -and $result.PendingFileRenameCheckSkipped) 'Read-only readiness must distinguish observed pending operations from the bypassed gate'
    Assert-Condition ($fixture.Warning -like '*BYPASSED*' -and $result.Operations.Count -eq 1) 'Read-only bypass must warn and retain the queue'
    $fixture.PendingKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $result = & $readinessPath -TargetComputer 'mock-target' -SkipPendingFileRenameCheck
    Assert-Condition ($result.UpgradeBlocked -and $fixture.Warning -like '*BLOCKED*') 'Read-only rename bypass must not ignore servicing reboot requirements'
    $credential = [pscredential]::new('test-user', (ConvertTo-SecureString 'test-placeholder' -AsPlainText -Force))
    foreach ($withCredential in @($false, $true)) {
        foreach ($transport in @('Http','Https','HttpsSkipCert')) {
            $readinessParams = @{ TargetComputer = 'mock-target' }
            if ($withCredential) { $readinessParams['Credential'] = $credential }
            if ($transport -ne 'Http') { $readinessParams['UseSSL'] = $true }
            if ($transport -eq 'HttpsSkipCert') { $readinessParams['SkipCertificateCheck'] = $true }
            & $readinessPath @readinessParams | Out-Null
            Assert-Condition ($fixture.Connection.ContainsKey('Authentication') -eq $withCredential) 'Readiness must preserve implicit authentication without credentials'
            if ($withCredential) {
                Assert-Condition ($fixture.Connection.Authentication -eq 'Negotiate' -and $fixture.Connection.Credential -eq $credential) 'Readiness must use the same explicit Negotiate credentials as kickoff'
            }
            Assert-Condition ([bool]$fixture.Connection.UseSSL -eq ($transport -ne 'Http')) 'Readiness changed transport'
            Assert-Condition (($fixture.Connection.SessionOption -eq 'SkipChecks') -eq ($transport -eq 'HttpsSkipCert')) 'Readiness bypassed certificate checks without permission'
        }
    }
    'PASS: read-only readiness command, reboot warning, boot metadata and HTTPS (mocked)'
}

& {
    . (Get-TestFunction $syntaxTrees['Update-UpgradeStatus.ps1'] 'Get-SetupPhaseEvidence')
    $path = Join-Path ([IO.Path]::GetTempPath()) ('SetupPhaseFixture_' + [guid]::NewGuid().ToString('N') + '.log')
    try {
        [IO.File]::WriteAllLines($path, @(
            '2025-01-01 10:00:00, Info SP Executing phase [Safe OS]',
            '2026-01-01 10:00:00, Info SP OPERATIONTRACK: Add phase: 4|Safe OS',
            '2026-01-01 10:00:01, Info SP OPERATIONTRACK: Enqueue Operation: Prepare SafeOS for rollback',
            '2026-01-01 10:00:02, Info SP OPERATIONTRACK ExecuteOperations: Start execution phase Downlevel',
            '2026-01-01 10:00:03, Info MOUPG Mapped Global progress: [100%]',
            '2026-01-01 10:00:04, Info SP Executing phase [Safe OS]',
            '2026-01-01 10:00:05, Info SP Executing phase [Pre SysPrep]',
            '2026-01-01 10:00:06, Info SP OPERATIONTRACK ExecuteOperations: Start execution phase Post First Boot',
            '2026-01-01 10:00:07, Info SP Executing phase [Pre OOBE]',
            '2026-01-01 10:00:08, Info SP Executing phase [Post OOBE]',
            '2026-01-01 10:00:09, Info SP Execution phase [Post OOBE] exiting with HRESULT [0x00000000]'
        ))
        $start = [DateTimeOffset]([datetime]'2026-01-01 10:00:00')
        $events = @(Get-SetupPhaseEvidence -Paths $path -StartedAtUtc $start)
        Assert-Condition (($events.Phase -join ',') -eq '3,4,5,5,6,6') 'Phase parser confused planned, completed, old-run or numeric progress lines with execution starts'
        Assert-Condition ($events[1].StartedAtUtc -eq $start.AddSeconds(4).ToUniversalTime().ToString('o')) 'Phase timestamp conversion is incorrect'
        Assert-Condition ($events[1].Evidence.Contains('Executing phase [Safe OS]')) 'Safe OS must retain the actual execution evidence'
        if ($SetupLogPath) {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $actual = @(Get-SetupPhaseEvidence -Paths $SetupLogPath -StartedAtUtc ([DateTimeOffset]'2026-09-29T00:00:00Z'))
            $watch.Stop()
            $distinct = @($actual | Group-Object Phase | ForEach-Object { $_.Group | Sort-Object StartedAtUtc | Select-Object -First 1 } | Sort-Object Phase)
            Assert-Condition (($distinct.Phase -join ',') -eq '3,4,5,6') 'Supplied setup log must confirm all four execution phases'
            foreach ($phase in $distinct) { "EVIDENCE: $($phase.PhaseName) $($phase.StartedAtUtc)" }
            "PASS: supplied setup log phase replay ($($watch.Elapsed.TotalSeconds.ToString('F2'))s, $($actual.Count) execution events)"
        }
        'PASS: current-run Setup phase evidence, timestamp conversion, and exclusion of planned operations'
    } finally {
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    }
}

& {
    foreach ($name in @('Get-UpgradeStageMetadata','ConvertTo-OverallUpgradePercent','Set-Phase','Get-UpgradeStatusSnapshot','Update-UpgradeBootEvidence')) {
        . (Get-TestFunction $syntaxTrees['OSUpgradeStatus.ps1'] $name)
    }
    $state = @{}
    $writeOrder = [Collections.Generic.List[string]]::new()
    function Get-UpgradeRegistryValue { param($Name, $Default = $null) if ($state.ContainsKey($Name)) { return $state[$Name] }; return $Default }
    function Set-UpgradeRegistryValue { param($Name, $Value, $Type) $state[$Name] = $Value; $writeOrder.Add($Name) }
    function Write-Log { param($Message, $Level) }
    function Write-StatusJson {}
    function New-Object { param($TypeName, $ArgumentList) if ($TypeName -ne 'System.Threading.Mutex') { throw "Unexpected type: $TypeName" }; New-TestMutex }
    function Get-ItemProperty { param($Path, $ErrorAction) return [pscustomobject]$state }
    foreach ($case in @(
        @{ Phase = 1; Local = 100; Overall = 10 },
        @{ Phase = 2; Local = 0; Overall = 10 },
        @{ Phase = 2; Local = 100; Overall = 25 },
        @{ Phase = 3; Local = 0; Overall = 25 },
        @{ Phase = 3; Local = 100; Overall = 50 },
        @{ Phase = 4; Local = 0; Overall = 50 },
        @{ Phase = 5; Local = 0; Overall = 70 },
        @{ Phase = 5; Local = 100; Overall = 85 },
        @{ Phase = 6; Local = 0; Overall = 85 },
        @{ Phase = 6; Local = 100; Overall = 95 },
        @{ Phase = 7; Local = 0; Overall = 95 },
        @{ Phase = 7; Local = 100; Overall = 99 }
    )) {
        Set-Phase -Phase $case.Phase -PhaseName "Phase $($case.Phase)" -PercentComplete $case.Local
        Assert-Condition ($state.PercentComplete -eq $case.Overall) "Incorrect workflow mapping for Phase $($case.Phase), local $($case.Local)"
        Assert-Condition ($state.PhasePercentComplete -eq $case.Local) 'Phase percentage must reset at phase boundaries, not inherit Downlevel 100'
    }
    Set-Phase -Phase 3 -PhaseName 'Late downlevel sample' -PercentComplete 100
    Assert-Condition ($state.Phase -eq 7 -and $state.PercentComplete -eq 99) 'Late monitor publication regressed the phase'
    Set-Phase -Phase 7 -PhaseName 'Completed' -Status Completed -PercentComplete 100
    Assert-Condition ($state.PercentComplete -eq 100) 'Only verified completion may reach 100'
    Assert-Condition ($writeOrder[$writeOrder.Count - 1] -eq 'Status') 'Terminal status must be committed after its percentage/evidence'
    Set-Phase -Phase 4 -PhaseName 'Late reboot' -Status InProgress
    Assert-Condition ($state.Status -eq 'Completed' -and $state.Phase -eq 7) 'A restart event must not resurrect a completed run'

    $state.Clear()
    Set-Phase -Phase 3 -PhaseName Downlevel -PercentComplete 50
    $priorPercent = $state.PercentComplete
    Set-Phase -Phase 99 -PhaseName 'Rolled Back' -Status Failed -PercentComplete 0 -ProgressFreshness Terminal
    Assert-Condition ($state.PercentComplete -eq $priorPercent -and $state.Status -eq 'Failed') 'Rollback must retain real achieved progress, not reset or advance it'
    $state['SetupPhaseHistory'] = '[{"Phase":4,"PhaseName":"Safe OS Phase","StartedAtUtc":"2026-01-01T10:00:00Z"}]'
    $state['UserProfileCount'] = 12
    $state['TotalProfileCount'] = 15
    $state['UserProfileCountLimit'] = 25
    $state['UserProfileCountCheckStatus'] = 'Passed'
    $state['OrphanedProfileCheckStatus'] = 'Skipped'
    $state['PendingFileRenameCheckStatus'] = 'Skipped'
    $snapshot = Get-UpgradeStatusSnapshot
    Assert-Condition ($snapshot.IsTerminal -and $snapshot.SetupPhaseHistory[0].Phase -eq 4) 'Structured history or terminal flag missing from target snapshot'
    Assert-Condition ($snapshot.UserProfileCount -eq 12 -and $snapshot.TotalProfileCount -eq 15 -and $snapshot.OrphanedProfileCheckStatus -eq 'Skipped') 'Readiness reporting fields missing from target snapshot'
    Assert-Condition (-not $snapshot.Contains('UserProfileCountLimit') -and -not $snapshot.Contains('UserProfileCountCheckStatus')) 'Retired profile gate fields must not be published, even if old registry values remain'
    Assert-Condition ($snapshot.PendingFileRenameCheckStatus -eq 'Skipped') 'Pending-file-rename gate reporting missing from target snapshot'

    $bootFixture = @{ Time = [datetime]'2026-01-01 10:00:00' }
    function Get-CimInstance { param($ClassName, $OperationTimeoutSec, $ErrorAction) [pscustomobject]@{ LastBootUpTime = $bootFixture.Time } }
    function Get-WinEvent { param($FilterHashtable, $MaxEvents, $ErrorAction) return $null }
    Assert-Condition (-not (Update-UpgradeBootEvidence)) 'Initial boot baseline must not count as a reboot'
    Assert-Condition (-not (Update-UpgradeBootEvidence)) 'Repeated event trigger must not count the same boot twice'
    $bootFixture.Time = $bootFixture.Time.AddMinutes(10)
    Assert-Condition (Update-UpgradeBootEvidence) 'Boot-time change must detect a reset even without Event 1074'
    Assert-Condition ($state.RebootCount -eq 1) 'Reset counted incorrectly'
    'PASS: phase-scoped progress, stage high-water, terminal guards, status schema, and unique reboot evidence'
}

& {
    foreach ($name in @('Get-UpgradeStageMetadata','ConvertTo-OverallUpgradePercent','Set-Phase')) {
        . (Get-TestFunction $syntaxTrees['OSUpgradeStatus.ps1'] $name)
    }
    . (Get-TestFunction $syntaxTrees['Update-UpgradeStatus.ps1'] 'Invoke-UpgradeStatusUpdate')
    $state = @{}
    $fixture = @{ Build = '17763'; Processes = @('setuphost'); Setup = 0; OOBE = 0; Marker = ''; BootChanged = $false; Unexpected = $false; Validation = 0; History = @() }
    $script:MarkerRB = 'C:\OfflineTest\rollback.marker'
    $script:MarkerOOBE = 'C:\OfflineTest\postoobe.marker'
    $script:RegRoot = 'HKLM:\SOFTWARE\OfflineUpgradeTest'
    function Get-UpgradeRegistryValue { param($Name, $Default = $null) if ($state.ContainsKey($Name)) { return $state[$Name] }; return $Default }
    function Set-UpgradeRegistryValue { param($Name, $Value, $Type) $state[$Name] = $Value }
    function Remove-ItemProperty { param($Path, $Name, $ErrorAction) $state.Remove($Name) }
    function New-Object { param($TypeName, $ArgumentList) New-TestMutex }
    function Write-StatusJson {}
    function Write-Log { param($Message, $Level) }
    function Test-Path { param($Path, $LiteralPath) return ($Path -eq $fixture.Marker) }
    function Get-ItemProperty {
        param($Path, $ErrorAction)
        if ($Path -like '*CurrentVersion') { return [pscustomobject]@{ CurrentBuildNumber = $fixture.Build } }
        if ($Path -eq 'HKLM:\SYSTEM\Setup') { return [pscustomobject]@{ SystemSetupInProgress = $fixture.Setup; OOBEInProgress = $fixture.OOBE } }
        throw "Unexpected registry query: $Path"
    }
    function Update-UpgradeBootEvidence { return $fixture.BootChanged }
    function Update-SetupPhaseHistory { return $fixture.History }
    function Get-WinEvent { param($FilterHashtable, $MaxEvents, $ErrorAction) if ($fixture.Unexpected) { [pscustomobject]@{ Id = 41 } } }
    function Get-Process { param($Name, $ErrorAction) return $fixture.Processes }
    function Get-SetupProgressPercent { [pscustomobject]@{ Percent = 100; Source = 'MoSetupRegistry' } }
    function Get-SetupLogTail { param($Path) return $null }
    function Get-ScheduledTaskInfo { param($TaskName, $ErrorAction) [pscustomobject]@{ LastTaskResult = 123 } }
    function Unregister-ScheduledTask { param($TaskName, $Confirm, $ErrorAction) }
    function Invoke-PostUpgradeValidation { $fixture.Validation++; Set-Phase -Phase 7 -PhaseName Completed -Status Completed -PercentComplete 100 }
    function Reset-MonitorFixture {
        $state.Clear()
        $state.SourceBuild = '17763'; $state.TargetBuild = '20348'; $state.Phase = 3
        $state.PhaseName = 'Downlevel Phase'; $state.Status = 'InProgress'
        $state.SetupLaunchTimeUtc = [DateTimeOffset]::UtcNow.AddMinutes(-30).ToString('o')
        $state.LastObservedBootTimeUtc = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o')
        $fixture.Build = '17763'; $fixture.Processes = @('setuphost'); $fixture.Marker = ''
        $fixture.Setup = 0; $fixture.OOBE = 0; $fixture.BootChanged = $false
        $fixture.Unexpected = $false; $fixture.Validation = 0; $fixture.History = @()
    }
    $RebootInitiated = $false
    Reset-MonitorFixture
    Invoke-UpgradeStatusUpdate
    Assert-Condition ($state.Phase -eq 3 -and $state.PercentComplete -eq 50) 'Downlevel 100 must not produce overall 95'

    $fixture.Processes = @()
    $fixture.BootChanged = $true
    $fixture.Unexpected = $true
    Invoke-UpgradeStatusUpdate
    Assert-Condition ($state.Status -eq 'InProgress' -and $state.Notes -like 'ATTENTION*') 'Forced reset must immediately surface missing-process diagnostics'
    Assert-Condition ([bool]$state.UnexpectedRestartAtUtc -and $state.ExpectedDisconnect -eq 0) 'Unexpected reset evidence was lost'
    $fixture.BootChanged = $false
    $state.SetupProcessMissingSinceUtc = [DateTimeOffset]::UtcNow.AddMinutes(-11).ToString('o')
    Invoke-UpgradeStatusUpdate
    Assert-Condition ($state.Status -eq 'Failed' -and $state.Phase -eq 3 -and $state.Notes -like '*Kindly check*') 'Stopped setup after reset must fail with the stage and diagnostics'
    Assert-Condition ($state.PercentComplete -eq 50) 'Reset failure must retain the achieved percentage'

    Reset-MonitorFixture
    $fixture.Processes = @()
    $state.Phase = 4; $state.PhaseName = 'Safe OS Phase'; $state.ExpectedDisconnect = 1
    $state.SetupProcessMissingSinceUtc = [DateTimeOffset]::UtcNow.AddMinutes(-11).ToString('o')
    Invoke-UpgradeStatusUpdate
    Assert-Condition ($state.Status -eq 'Failed') 'Legacy ExpectedDisconnect/Phase 4 must not bypass process-liveness failure forever'

    Reset-MonitorFixture
    $fixture.Processes = @()
    $state.SetupProcessMissingSinceUtc = [DateTimeOffset]::UtcNow.AddMinutes(-9.9).ToString('o')
    Invoke-UpgradeStatusUpdate
    Assert-Condition ($state.Status -eq 'InProgress') 'Missing-process grace must not fail before ten minutes'
    $state.SetupProcessMissingSinceUtc = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o')
    $fixture.History = @([pscustomobject]@{ Phase = 5; PhaseName = 'First Boot Phase' })
    Invoke-UpgradeStatusUpdate
    Assert-Condition ($state.Status -eq 'Failed' -and $state.Phase -eq 5 -and $state.Notes -like '*last confirmed phase*First Boot*') 'Failure reporting must use recovered execution evidence instead of an obsolete Downlevel sample'

    Reset-MonitorFixture
    $state.SetupProcessMissingSinceUtc = [DateTimeOffset]::UtcNow.AddMinutes(-11).ToString('o')
    Invoke-UpgradeStatusUpdate
    Assert-Condition ($state.Status -eq 'InProgress' -and -not $state.ContainsKey('SetupProcessMissingSinceUtc')) 'A resumed Setup process must clear the missing-process grace timer'

    Reset-MonitorFixture
    $fixture.Build = '20348'; $fixture.Setup = 1
    Invoke-UpgradeStatusUpdate
    Assert-Condition ($state.Phase -eq 5 -and $state.PercentComplete -eq 85) 'Live target build during Setup must identify First Boot and cap progress'
    $fixture.OOBE = 1
    Invoke-UpgradeStatusUpdate
    Assert-Condition ($state.Phase -eq 6 -and $fixture.Validation -eq 0) 'Active OOBE must not be called complete'

    foreach ($withMarker in @($false, $true)) {
        Reset-MonitorFixture
        $state.Phase = 7; $state.PhaseName = 'Post-Upgrade Validation'
        $state.OverallPercentComplete = 95
        $fixture.Build = '20348'; $fixture.Processes = @()
        if ($withMarker) { $fixture.Marker = $script:MarkerOOBE }
        Invoke-UpgradeStatusUpdate
        Assert-Condition ($fixture.Validation -eq 1 -and $state.PercentComplete -eq 100) "Interrupted Phase 7 must resume validation (marker=$withMarker)"
    }
    Reset-MonitorFixture
    $fixture.Build = '20348'; $fixture.Processes = @(); $fixture.Setup = $null; $fixture.OOBE = $null
    Invoke-UpgradeStatusUpdate
    Assert-Condition ($fixture.Validation -eq 0 -and $state.Status -eq 'InProgress') 'Missing Setup flags must not be interpreted as completion'

    Reset-MonitorFixture
    $RebootInitiated = $true
    Invoke-UpgradeStatusUpdate
    Assert-Condition ($state.Phase -eq 3 -and $state.ExpectedDisconnect -eq 1) 'Event 1074 alone must not label Safe OS'
    $state.Status = 'Completed'; $state.Phase = 7
    Invoke-UpgradeStatusUpdate
    Assert-Condition ($state.Status -eq 'Completed' -and $state.Phase -eq 7) 'Late reboot watcher must preserve terminal completion'
    $RebootInitiated = $false
    Reset-MonitorFixture
    $fixture.Marker = $script:MarkerRB
    $fixture.History = @([pscustomobject]@{ Phase = 5; PhaseName = 'First Boot Phase' })
    Invoke-UpgradeStatusUpdate
    Assert-Condition ($state.Phase -eq 99 -and $state.Status -eq 'Failed') 'Rollback hook must take precedence'
    $rollbackNotes = $state.Notes
    Invoke-UpgradeStatusUpdate
    Assert-Condition ($state.Notes -eq $rollbackNotes -and $rollbackNotes -like '*First Boot*') 'Repeated rollback callbacks must preserve the last confirmed failure phase'
    Reset-MonitorFixture
    $fixture.Build = '99999'
    Invoke-UpgradeStatusUpdate
    Assert-Condition ($state.Status -eq 'Failed' -and $state.Notes -like '*Unexpected live build*') 'Unexpected build must not silently stall'
    'PASS: reset recovery, missing processes, legacy reboot trap, First Boot/OOBE, interrupted validation, missing hooks/flags, and rollback'
}

& {
    . (Get-TestFunction $syntaxTrees['Update-UpgradeStatus.ps1'] 'Invoke-PostUpgradeValidation')
    $fixture = @{ Build = '17763'; Calls = @(); Unregistered = 0 }
    $targetBuild = '20348'
    function Set-Phase { param($Phase, $PhaseName, $Status, $PercentComplete, $PercentSource, $ProgressSource, $ProgressFreshness, $Notes) $fixture.Calls += [pscustomobject]$PSBoundParameters }
    function Get-CimInstance {
        param($ClassName, $OperationTimeoutSec, $ErrorAction)
        if ($ClassName -eq 'Win32_OperatingSystem') { return [pscustomobject]@{ BuildNumber = $fixture.Build; Caption = 'Test OS' } }
        if ($ClassName -eq 'SoftwareLicensingProduct') { return [pscustomobject]@{ PartialProductKey = 'TEST'; LicenseStatus = 1 } }
        throw "Unexpected class $ClassName"
    }
    function Get-ItemProperty { param($Path, $Name, $ErrorAction) [pscustomobject]@{ CurrentBuildNumber = $fixture.Build; EditionID = 'ServerDatacenter' } }
    function Get-UpgradeRegistryValue { param($Name, $Default) if ($Name -eq 'SourceEditionId') { return 'ServerDatacenter' }; return $Default }
    function Set-UpgradeRegistryValue { param($Name, $Value, $Type) }
    function Get-Service { param($Name, $ErrorAction) [pscustomobject]@{ Status = 'Running' } }
    function Write-Log { param($Message, $Level) }
    function Unregister-ScheduledTask { param($TaskName, $Confirm, $ErrorAction) $fixture.Unregistered++ }
    Invoke-PostUpgradeValidation
    Assert-Condition ($fixture.Calls[-1].Status -eq 'Failed' -and $fixture.Unregistered -eq 0) 'Wrong build must not become CompletedWithWarnings or stop all retries as success'
    $fixture.Build = '20348'; $fixture.Calls = @()
    Invoke-PostUpgradeValidation
    Assert-Condition ($fixture.Calls[-1].Status -eq 'Completed' -and $fixture.Calls[-1].PercentComplete -eq 100) 'Verified target build and successful validation must complete'
    Assert-Condition ($fixture.Unregistered -eq 3) 'Successful validation must clean up the three monitoring/launch tasks'
    'PASS: actual validation rejects wrong-build success and completes a verified target'
}

& {
    foreach ($name in @('Add-UpgradeObservation','Get-UpgradeHealthWarning','Get-UpgradeCompletionCheck','ConvertTo-ProducerStatusRecord')) {
        . (Get-TestFunction $syntaxTrees['Start-RemoteUpgradeOrchestrator.ps1'] $name)
    }
    function Write-Log { param($Message, $Level) }
    $now = [DateTimeOffset]::UtcNow
    $script:ExpectedRunId = 'run-current'
    $script:LastProducerStatus = @{ RunId = 'run-current'; Sequence = 10 }
    $record = [pscustomobject]@{
        RunId = 'run-current'; Sequence = 11; Phase = 3; PhaseName = 'Downlevel'
        Status = 'InProgress'; PercentComplete = 50; StatusUpdatedAtUtc = $now.AddMinutes(-6).ToString('o')
    }
    $accepted = Add-UpgradeObservation -Record $record -WinRmOk $true -PingOk $false -Source 'test'
    Assert-Condition ($accepted.Mode -eq 'ActivePolling' -and -not $accepted.PingOk) 'Blocked ICMP must not force Offline mode'
    $warning = Get-UpgradeHealthWarning -Status $accepted -LastProducer $accepted -LastAdvanceAtUtc $now -StaleMinutes 5 -NowUtc $now
    Assert-Condition ($warning -like '*stale/unavailable*' -and $warning -like '*Downlevel*') 'Repeatedly readable stale JSON must still trigger the watchdog'
    $offline = [pscustomobject]@{ Mode = 'Offline' }
    $record.StatusUpdatedAtUtc = $now.ToString('o')
    $warning = Get-UpgradeHealthWarning -Status $offline -LastProducer $record -LastAdvanceAtUtc $now.AddMinutes(-6) -StaleMinutes 5 -NowUtc $now
    Assert-Condition ($warning -like '*Completion is NOT confirmed*') 'Offline timeout must not fabricate success or failure'
    $record.Sequence = 9
    Assert-Condition ($null -eq (Add-UpgradeObservation -Record $record -Source 'stale')) 'Older sequence must be rejected'
    $record.Sequence = 11; $record.RunId = 'other-run'
    Assert-Condition ($null -eq (Add-UpgradeObservation -Record $record -Source 'wrong-run')) 'Wrong run identity must be rejected'
    $complete = [pscustomobject]@{
        Status = 'Completed'; Mode = 'ActivePolling'
        LiveState = [pscustomobject]@{ CurrentBuild = '20348'; SystemSetupInProgress = 0; OOBEInProgress = 0 }
    }
    Assert-Condition (Get-UpgradeCompletionCheck -Status $complete -TargetBuild '20348').Confirmed 'Live target build and clear Setup flags must complete'
    foreach ($badBuild in @('', '17763')) {
        $check = Get-UpgradeCompletionCheck -Status $complete -TargetBuild $badBuild
        Assert-Condition (-not $check.Confirmed -and [bool]$check.Reason) 'Missing/wrong expected build must explicitly block completion'
    }
    $complete.LiveState.OOBEInProgress = 1
    Assert-Condition (-not (Get-UpgradeCompletionCheck -Status $complete -TargetBuild '20348').Confirmed) 'Active OOBE must block completion'
    $complete.LiveState.OOBEInProgress = $null
    Assert-Condition (-not (Get-UpgradeCompletionCheck -Status $complete -TargetBuild '20348').Confirmed) 'Unknown OOBE must block completion'
    $complete.LiveState = $null
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        Assert-Condition (-not (Get-UpgradeCompletionCheck -Status $complete -TargetBuild '20348').Confirmed) 'Repeated verification failures must never turn into success'
    }
    $producerOnly = ConvertTo-ProducerStatusRecord -Status $complete
    Assert-Condition (-not $producerOnly.Contains('LiveState')) 'Live observer data must not overwrite the producer contract'
    $script:ExpectedRunId = $null; $script:LastProducerStatus = $null
    'PASS: stale-file/offline watchdog, run/sequence validation, blocked ICMP and strict terminal verification'
}

& {
    . (Get-TestFunction $syntaxTrees['OSUpgradeStatus.ps1'] 'Get-UpgradeDiskDirtyState')
    . (Get-TestFunction $syntaxTrees['OSUpgradeStatus.ps1'] 'Get-UpgradeUserProfileInventory')
    $fixture = @{
        Exit = 0; Text = 'Volume C: is not dirty'; NativeCalls = @()
        Volumes = @([pscustomobject]@{ DriveLetter = $env:SystemDrive; DirtyBitSet = $false })
        Profiles = @(
            [pscustomobject]@{ SID = 'local-user'; LocalPath = 'C:\Users\local'; Special = $false; Loaded = $true },
            [pscustomobject]@{ SID = 'domain-or-orphan'; LocalPath = 'C:\Users\domain'; Special = $false; Loaded = $false },
            [pscustomobject]@{ SID = 'system'; LocalPath = 'C:\Windows\System32\config\systemprofile'; Special = $true; Loaded = $true }
        )
    }
    function Get-CimInstance {
        param($ClassName, $Filter, $ErrorAction)
        if ($ClassName -eq 'Win32_Volume') { return $fixture.Volumes }
        if ($ClassName -eq 'Win32_UserProfile') { return $fixture.Profiles }
        throw "Unexpected class: $ClassName"
    }
    function fsutil.exe { param($Verb, $Operation, $Volume) $fixture.NativeCalls += "$Verb $Operation $Volume"; $global:LASTEXITCODE = $fixture.Exit; return $fixture.Text }
    Assert-Condition (-not (Get-UpgradeDiskDirtyState).IsDirty) 'Clean volume interpreted as dirty'
    $fixture.Text = 'Volume C: is dirty'
    Assert-Condition (Get-UpgradeDiskDirtyState).IsDirty 'Dirty volume must be detected even when fsutil exits zero'
    $fixture.Text = 'Localized utility output'; $fixture.Volumes[0].DirtyBitSet = $true
    Assert-Condition (Get-UpgradeDiskDirtyState).IsDirty 'Non-English fsutil output must use the typed CIM bit'
    $fixture.Volumes[0].DirtyBitSet = $null
    $threw = $false; try { Get-UpgradeDiskDirtyState | Out-Null } catch { $threw = $true }
    Assert-Condition $threw 'Unknown dirty bit must fail closed, not pass'
    $fixture.Exit = 5
    $threw = $false; try { Get-UpgradeDiskDirtyState | Out-Null } catch { $threw = $true }
    Assert-Condition $threw 'fsutil failure must fail closed'
    Assert-Condition (@($fixture.NativeCalls | Where-Object { $_ -notlike 'dirty query *' }).Count -eq 0) 'Dirty-bit precheck must never set/clear or repair volumes'
    $global:LASTEXITCODE = 0
    $profiles = Get-UpgradeUserProfileInventory
    Assert-Condition ($profiles.UserProfileCount -eq 2 -and $profiles.TotalProfileCount -eq 3 -and $profiles.SpecialProfileCount -eq 1 -and $profiles.LoadedUserProfileCount -eq 1) 'Profile count must include local/domain/orphan users and distinguish system profiles'
    $fixture.Profiles = @()
    Assert-Condition ((Get-UpgradeUserProfileInventory).TotalProfileCount -eq 0) 'Empty successful profile enumeration must be zero'
    $fixture.Profiles = @([pscustomobject]@{ SID = 'invalid'; Special = $null })
    $threw = $false; try { Get-UpgradeUserProfileInventory | Out-Null } catch { $threw = $true }
    Assert-Condition $threw 'Incomplete profile metadata must be reported as unknown'
    'PASS: read-only dirty-bit checks, localized output, fail-closed errors, and exact profile counts'
}

& {
    $tree = $syntaxTrees['Start-TargetUpgrade.ps1']
    $bypass = $tree.Find({
        param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '$SkipOrphanedProfileCheck'
    }, $true)
    Assert-Condition ($null -ne $bypass) 'Explicit orphan-profile bypass is missing'
    $fixture = @{ Status = ''; Result = ''; Reads = 0 }
    function Set-UpgradeRegistryValue { param($Name, $Value, $Type) $fixture.Status = $Value }
    function Add-PreCheckResult { param($Name, $Result, $Detail) $fixture.Result = $Result }
    function Get-ChildItem { $fixture.Reads++; throw 'SID enumeration must not run when bypassed' }
    $SkipOrphanedProfileCheck = $true
    . ([scriptblock]::Create($bypass.Extent.Text))
    Assert-Condition ($fixture.Status -eq 'Skipped' -and $fixture.Result -eq 'WARN' -and $fixture.Reads -eq 0) 'Bypass must explicitly report WARN/Skipped and avoid account resolution'
    $SkipOrphanedProfileCheck = $false
    . ([scriptblock]::Create($bypass.Extent.Text))
    Assert-Condition ($fixture.Status -eq 'Unknown' -and $fixture.Result -eq 'WARN' -and $fixture.Reads -eq 1) 'Registry enumeration failure must not be reported as no orphaned profiles'
    $names = @($tree.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Add-PreCheckResult'
    }, $true) | ForEach-Object {
        for ($i = 0; $i -lt $_.CommandElements.Count - 1; $i++) {
            if ($_.CommandElements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $_.CommandElements[$i].ParameterName -eq 'Name') {
                $_.CommandElements[$i + 1].Value
            }
        }
    } | ForEach-Object {
        if ($_ -like 'ISO edition matches current OS*') { 'ISO edition matches current OS' }
        elseif ($_ -like 'VMware Tools*') { 'VMware Tools check' }
        else { $_ }
    } | Sort-Object -Unique)
    Assert-Condition ($names.Count -eq 16) "Expected exactly 16 distinct prechecks, found $($names.Count)"
    foreach ($file in @('Start-TargetUpgrade.ps1','Start-RemoteUpgradeOrchestrator.ps1')) {
        foreach ($flag in @('SkipOrphanedProfileCheck','SkipUserProfileCountCheck','SkipPendingFileRenameCheck')) {
            $parameter = $syntaxTrees[$file].ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $flag }
            Assert-Condition ($null -ne $parameter -and $null -eq $parameter.DefaultValue) "$file $flag must default off"
            Assert-Condition ($syntaxTrees['Start-RemoteUpgradeOrchestrator.ps1'].Extent.Text -match ($flag + '\s*=\s*\[bool\]\$' + $flag)) "$flag is not passed through to the target"
        }
    }
    Assert-Condition ($syntaxTrees['Start-RemoteUpgradeOrchestrator.ps1'].Extent.Text -match 'SkipOrphanedProfileCheck\s*=\s*\[bool\]\$SkipOrphanedProfileCheck') 'Orphan bypass is not passed through to the target'
    'PASS: explicit default-off orphan bypass, passthrough, and 16-check accounting'
}

& {
    . (Get-TestFunction $syntaxTrees['Start-RemoteUpgradeOrchestrator.ps1'] 'Get-RemoteUpgradeObservation')
    $helperPath = Join-Path $projectRoot 'ServerB-Target\OSUpgradeStatus.ps1'
    $bootTime = [datetime]'2026-01-01 10:00:00'
    $fixture = @{
        Invoke = $null; Starts = 0; Registers = 0; TaskState = 'Ready'; MissingScript = $false
        CurrentBuild = '17763'; Setup = 0; Processes = @('setuphost'); Removed = 0
        Settings = $null
        Registry = [pscustomobject]@{
            RunId = 'test-run'; Sequence = 1; Phase = 3; Status = 'InProgress'
            SourceBuild = '17763'; TargetBuild = '20348'
            LastObservedBootTimeUtc = $bootTime.ToUniversalTime().ToString('o')
            StatusUpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            SetupPhaseHistory = '[]'
        }
    }
    function New-Object { param($TypeName, $ArgumentList) New-TestMutex }
    function Join-Path {
        param($Path, $ChildPath)
        if ($ChildPath -eq 'Scripts\OSUpgradeStatus.ps1') { return $helperPath }
        Microsoft.PowerShell.Management\Join-Path -Path $Path -ChildPath $ChildPath
    }
    function Test-Path { param($LiteralPath, $Path) return (-not ($fixture.MissingScript -and $LiteralPath -like '*Update-UpgradeStatus.ps1')) }
    function Get-ItemProperty {
        param($Path, $Name, $ErrorAction)
        switch ($Path) {
            'HKLM:\SOFTWARE\OSUpgradeAutomation' { return $fixture.Registry }
            'HKLM:\SYSTEM\Setup' { return [pscustomobject]@{ SystemSetupInProgress = $fixture.Setup; OOBEInProgress = 0 } }
            'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' { return [pscustomobject]@{ CurrentBuildNumber = $fixture.CurrentBuild } }
        }
        throw "Unexpected registry read: $Path"
    }
    function Get-Process { param($Name, $ErrorAction) return $fixture.Processes }
    function Get-CimInstance {
        [CmdletBinding()]
        param($ClassName, $OperationTimeoutSec)
        return [pscustomobject]@{ LastBootUpTime = $bootTime }
    }
    function Get-ScheduledTask { param($TaskName, $ErrorAction) if ($fixture.TaskState) { return [pscustomobject]@{ State = $fixture.TaskState } } }
    function New-ScheduledTaskAction { param($Execute, $Argument) Assert-Condition ($Argument -like '*Update-UpgradeStatus.ps1*') 'Recovery must launch only the status monitor'; return 'action' }
    function New-ScheduledTaskTrigger { param([switch]$Once, $At, $RepetitionInterval, $RepetitionDuration, [switch]$AtStartup) return 'trigger' }
    function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel) return 'principal' }
    function New-ScheduledTaskSettingsSet {
        param([switch]$StartWhenAvailable, $MultipleInstances, [switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, $ExecutionTimeLimit)
        $fixture.Settings = $PSBoundParameters
        return 'settings'
    }
    function Register-ScheduledTask { param($TaskName, $Action, $Trigger, $Principal, $Settings) $fixture.Registers++; Assert-Condition ($TaskName -eq 'OSUpgradePhaseMonitor') 'Recovery must not register Setup again' }
    function Start-ScheduledTask { param($TaskName, $ErrorAction) $fixture.Starts++; Assert-Condition ($TaskName -eq 'OSUpgradePhaseMonitor') 'Recovery must not restart Setup' }
    function New-PSSessionOption {
        param($OpenTimeout, $OperationTimeout, [switch]$SkipCACheck, [switch]$SkipCNCheck, [switch]$SkipRevocationCheck)
        return [pscustomobject]$PSBoundParameters
    }
    function Invoke-Command {
        param($ComputerName, $Credential, $Authentication, [switch]$UseSSL, $Port, $SessionOption, $ScriptBlock, $ErrorAction)
        $fixture.Invoke = $PSBoundParameters
        if ($Credential -and $Authentication -ne 'Negotiate') { throw 'Explicit credentials require Negotiate' }
        & $ScriptBlock
    }
    function Start-Job { param($ScriptBlock, [object[]]$ArgumentList) [pscustomobject]@{ Output = (& $ScriptBlock @ArgumentList) } }
    function Wait-Job { param($Job, $Timeout) return $Job }
    function Receive-Job { param($Job, $ErrorVariable, $ErrorAction) return $Job.Output }
    function Stop-Job { param($Job, $ErrorAction) }
    function Remove-Job { param($Job, [switch]$Force, $ErrorAction) $fixture.Removed++ }
    $credential = [pscredential]::new('test-user', (ConvertTo-SecureString 'test-placeholder' -AsPlainText -Force))
    foreach ($withCredential in @($false, $true)) {
      $selectedCredential = if ($withCredential) { $credential } else { $null }
      foreach ($transport in @('Http','Https','HttpsSkipCert')) {
        $observation = Get-RemoteUpgradeObservation -ComputerName 'mock-target' -Cred $selectedCredential -Transport $transport
        Assert-Condition ($observation.ProducerStatus.RunId -eq 'test-run' -and $observation.LiveState.CurrentBuild -eq '17763') 'Live probe lost registry/build evidence'
        Assert-Condition (-not $observation.LiveState.ProbeWarning) 'Authenticated remote observation must not pass unsupported Credential to Get-CimInstance'
        Assert-Condition ($fixture.Invoke.Credential -eq $selectedCredential -and $fixture.Invoke.SessionOption.OpenTimeout -eq 5000) 'Live probe lost credentials or timeout'
        Assert-Condition ($fixture.Invoke.ContainsKey('Authentication') -eq $withCredential) 'Live/final validation reader changed implicit authentication'
        if ($withCredential) { Assert-Condition ($fixture.Invoke.Authentication -eq 'Negotiate') 'Live/final validation reader must use Negotiate with credentials' }
        Assert-Condition ([bool]$fixture.Invoke.UseSSL -eq ($transport -ne 'Http')) 'Live probe used the wrong transport'
        Assert-Condition ([bool]$fixture.Invoke.SessionOption.SkipCACheck -eq ($transport -eq 'HttpsSkipCert')) 'Live probe bypassed certificate checks without permission'
      }
    }
    Assert-Condition ($fixture.Starts -eq 0 -and $fixture.Registers -eq 0) 'Healthy source-OS monitor must not be needlessly repaired'
    $fixture.CurrentBuild = '20348'; $fixture.Processes = @()
    $observation = Get-RemoteUpgradeObservation -ComputerName 'mock-target' -Transport Http
    Assert-Condition ($fixture.Starts -eq 1 -and $observation.LiveState.MonitorRecovery -like '*immediate*') 'Target build with stale Downlevel status must trigger validation refresh'
    $fixture.TaskState = 'Running'
    Get-RemoteUpgradeObservation -ComputerName 'mock-target' -Transport Http | Out-Null
    Assert-Condition ($fixture.Starts -eq 1) 'Do not create overlapping validation runs'
    $fixture.TaskState = $null
    $observation = Get-RemoteUpgradeObservation -ComputerName 'mock-target' -Transport Http
    Assert-Condition ($fixture.Registers -eq 1 -and $fixture.Starts -eq 2) 'Lost monitor task must be recreated and started'
    Assert-Condition ($fixture.Settings.ExecutionTimeLimit.TotalMinutes -eq 10) 'Recovered monitor must have a bounded execution time'
    $fixture.MissingScript = $true
    $observation = Get-RemoteUpgradeObservation -ComputerName 'mock-target' -Transport Http
    Assert-Condition ($observation.LiveState.MonitorRecoveryError -like '*Monitor script missing*' -and $fixture.Starts -eq 2) 'Failed recovery must be explicit, not success-shaped'
    Assert-Condition ($fixture.Removed -eq 10) 'Every live observation must clean up its job'
    'PASS: live registry/build probing, HTTP/HTTPS identity, missing monitor repair, and no Setup relaunch (mocked)'
}

& {
    foreach ($name in @('Get-RemoteStatusViaCimDcom','Get-RemoteUpgradeObservation')) {
        . (Get-TestFunction $syntaxTrees['Start-RemoteUpgradeOrchestrator.ps1'] $name)
    }
    function Start-Job {
        param($ScriptBlock, $ArgumentList)
        # Replace remote work with a local sleep; exercise real job deadlines and cleanup.
        Microsoft.PowerShell.Core\Start-Job -ScriptBlock { Start-Sleep -Seconds 30 }
    }
    foreach ($reader in @('Get-RemoteStatusViaCimDcom','Get-RemoteUpgradeObservation')) {
        $beforeJobs = @(Get-Job).Count
        $detail = $null
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $argsForReader = @{ ComputerName = 'unused'; TimeoutSec = 1; ErrorDetail = [ref]$detail }
        if ($reader -eq 'Get-RemoteUpgradeObservation') { $argsForReader['Transport'] = 'Http' }
        $result = & $reader @argsForReader
        $watch.Stop()
        Assert-Condition ($null -eq $result -and $detail -like '*timed out*') "$reader must report a bounded timeout"
        Assert-Condition ($watch.Elapsed.TotalSeconds -lt 8) "$reader blocked past its hard deadline/cleanup allowance"
        Assert-Condition (@(Get-Job).Count -eq $beforeJobs) "$reader leaked its timed-out job"
    }
    'PASS: actual job timeout and cleanup for entire DCOM and live WinRM reads (local sleeps, no network)'
}

& {
    foreach ($name in @('Get-UpgradeStatus','Add-UpgradeObservation')) {
        . (Get-TestFunction $syntaxTrees['Start-RemoteUpgradeOrchestrator.ps1'] $name)
    }
    $script:ExpectedRunId = 'test-run'; $script:LastProducerStatus = $null; $script:WinRMTransport = 'Http'
    $fixture = @{ WinRM = $true; Observation = $null; File = $null; DCOM = $null; FileReads = 0; DcomReads = 0 }
    function New-Object {
        param($TypeName)
        if ($TypeName -ne 'System.Net.NetworkInformation.Ping') { throw "Unexpected type: $TypeName" }
        $ping = [pscustomobject]@{}
        $ping | Add-Member ScriptMethod Send { param($ComputerName, $Timeout) return [pscustomobject]@{ Status = 'TimedOut' } }
        $ping | Add-Member ScriptMethod Dispose {}
        return $ping
    }
    function Test-RemoteWinRM { param($ComputerName, $Cred, $TimeoutSec) return $fixture.WinRM }
    function Get-RemoteUpgradeObservation { param($ComputerName, $Cred, $Transport, $ErrorDetail) return $fixture.Observation }
    function Read-RemoteFileWithTimeout { param($Path, $TimeoutSec, $ErrorDetail) $fixture.FileReads++; return $fixture.File }
    function Get-RemoteStatusViaCimDcom { param($ComputerName, $Cred, $ErrorDetail) $fixture.DcomReads++; return $fixture.DCOM }
    function Read-RemoteStatusJsonViaWinRM { param($ComputerName, $Cred, $JsonPath, $Transport, $ErrorDetail) return $null }
    function Write-Log { param($Message, $Level) }
    $fresh = [pscustomobject]@{ RunId = 'test-run'; Sequence = 12; Phase = 7; Status = 'Completed'; PercentComplete = 100; StatusUpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
    $fixture.Observation = [pscustomobject]@{ ProducerStatus = $fresh; LiveState = [pscustomobject]@{ CurrentBuild = '20348'; SystemSetupInProgress = 0; OOBEInProgress = 0 } }
    $fixture.File = '{"RunId":"test-run","Sequence":10,"Phase":3,"Status":"InProgress","PercentComplete":95,"StatusUpdatedAtUtc":"2026-01-01T00:00:00Z"}'
    $status = Get-UpgradeStatus -ComputerName 'mock-target' -JsonPath 'D:\upgrade_status.json'
    Assert-Condition ($status.PercentComplete -eq 100 -and $status.Source -eq 'WinRM(LiveRegistry)' -and $fixture.FileReads -eq 0 -and $fixture.DcomReads -eq 0) 'Stale SMB at 95 must not shadow live completion or delay WinRM-only status'
    $fixture.Observation = $null; $fixture.DCOM = $fresh
    $status = Get-UpgradeStatus -ComputerName 'mock-target' -JsonPath 'D:\upgrade_status.json'
    Assert-Condition ($status.Source -eq 'CIM(DCOM)' -and $status.Sequence -eq 12) 'Newer DCOM state must win over stale SMB when live WinRM read fails'
    $fixture.WinRM = $false; $fixture.File = $null; $fixture.DCOM = $null
    $status = Get-UpgradeStatus -ComputerName 'mock-target' -JsonPath 'D:\upgrade_status.json'
    Assert-Condition ($status.Mode -eq 'Offline' -and $null -eq $status.Phase -and $status.Status -eq 'Unknown') 'Loss of all channels must not assert Safe OS or successful completion'
    $script:ExpectedRunId = $null; $script:LastProducerStatus = $null
    'PASS: actual status acquisition prefers live completion, handles blocked SMB, and avoids connectivity-based phase guesses'
}

& {
    foreach ($name in @('Write-LocalStatusMirror','ConvertTo-ProducerStatusRecord')) {
        . (Get-TestFunction $syntaxTrees['Start-RemoteUpgradeOrchestrator.ps1'] $name)
    }
    function Write-Log { param($Message, $Level) throw "Unexpected mirror error: $Message" }
    $TargetComputer = 'offline-test'
    $script:LocalStatusMirrorPath = Join-Path ([IO.Path]::GetTempPath()) ('UpgradeMirror_' + [guid]::NewGuid().ToString('N') + '.json')
    $script:LastProducerStatus = $null; $script:LastProducerReadAtUtc = $null
    $script:ProducerCacheRecovered = $false; $script:MirrorWriteWarningLogged = $false
    $producer = [pscustomobject]@{
        RunId = 'mirror-run'; Sequence = 10; Phase = 3; Status = 'InProgress'
        PhaseName = 'Downlevel Phase'; PercentComplete = 50
        StatusUpdatedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-6).ToString('o')
        SetupPhaseHistory = @([pscustomobject]@{ Phase = 4; PhaseName = 'Safe OS Phase' })
    }
    try {
        Write-LocalStatusMirror -ProducerStatus $producer -ObservationStatus ([pscustomobject]@{ Mode = 'ActivePolling'; HealthWarning = 'stale publisher' })
        $first = Get-Content -LiteralPath $script:LocalStatusMirrorPath -Raw | ConvertFrom-Json
        Assert-Condition ($first.Observer.CacheState -eq 'Fresh' -and $first.Observer.ProducerStatusAgeSeconds -ge 360) 'Mirror must distinguish fresh reads from stale publication'
        Write-LocalStatusMirror -ObservationStatus ([pscustomobject]@{ Mode = 'Offline'; HealthWarning = 'check target' })
        $cached = Get-Content -LiteralPath $script:LocalStatusMirrorPath -Raw | ConvertFrom-Json
        Assert-Condition ($cached.RunId -eq 'mirror-run' -and $cached.Sequence -eq 10 -and $cached.PercentComplete -eq 50 -and $cached.Phase -eq 3) 'Connectivity outage changed producer phase/progress'
        Assert-Condition ($cached.SetupPhaseHistory[0].Phase -eq 4 -and $cached.Observer.CacheState -eq 'CarriedForward' -and $cached.Observer.HealthWarning -eq 'check target') 'Mirror lost phase evidence or observer health'
        Assert-Condition ($cached.Observer.LastProducerReadAtUtc -eq $first.Observer.LastProducerReadAtUtc) 'An offline observation must not refresh producer-read time'
        'PASS: persisted atomic mirror preserves producer state and reports independent status age/health during outages'
    } finally {
        if ([IO.File]::Exists($script:LocalStatusMirrorPath)) { [IO.File]::Delete($script:LocalStatusMirrorPath) }
        $script:LastProducerStatus = $null; $script:LastProducerReadAtUtc = $null
    }
}

& {
    $tree = $syntaxTrees['Start-RemoteUpgradeOrchestrator.ps1']
    foreach ($name in @('Get-UpgradeHealthWarning','Get-UpgradeCompletionCheck','Add-UpgradeObservation','Wait-UpgradeCompletion')) {
        . (Get-TestFunction $tree $name)
    }
    $loop = $tree.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.WhileStatementAst] -and $_.Condition.Extent.Text -eq '$true'
    } | Select-Object -First 1
    $initialization = $tree.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$startTime'
    } | Select-Object -First 1
    Assert-Condition ($null -ne $loop -and $null -ne $initialization) 'Main monitor loop/initialization missing'
    $monitorCode = [scriptblock]::Create($tree.Extent.Text.Substring($initialization.Extent.StartOffset, $loop.Extent.EndOffset - $initialization.Extent.StartOffset))
    $fixture = @{ Queue = [Collections.Generic.Queue[object]]::new(); Messages = @(); Percentages = @(); Sleeps = 0 }
    function Get-UpgradeStatus { param($ComputerName, $Cred, $JsonPath) if (-not $fixture.Queue.Count) { throw 'Fixture exhausted before a terminal decision' }; return $fixture.Queue.Dequeue() }
    function Write-Log { param($Message, $Level, [switch]$LogOnly) if (-not $LogOnly) { $fixture.Messages += $Message } }
    function Write-Progress { param($Activity, $Status, $PercentComplete) }
    function Get-RemoteUpgradeObservation {
        param($ComputerName, $Cred, $Transport, $TimeoutSec, $ErrorDetail)
        $next = Get-UpgradeStatus
        [pscustomobject]@{ ProducerStatus = $next; LiveState = $next.LiveState }
    }
    function Write-LocalStatusMirror { param($ProducerStatus, $ObservationStatus, $ObservationError) if ($ProducerStatus) { $script:LastProducerStatus = $ProducerStatus } }
    function Show-ProgressBar {
        param($PercentComplete, $PhaseName, $Status, $PingOk, $Mode, $Source, $PercentSource, $ProgressSource, $ProgressFreshness, $Stage)
        $fixture.Percentages += $PercentComplete
    }
    function Start-Sleep { param($Seconds, $Milliseconds) $fixture.Sleeps++; if ($fixture.Sleeps -gt 6) { throw 'Monitor failed to reach a bounded terminal decision' } }
    $TargetComputer = 'offline-test'; $StatusJsonPath = 'D:\upgrade_status.json'
    $resumeExisting = $false; $PollIntervalSeconds = 15; $FastPollIntervalSeconds = 5
    $PhaseStallWarningMinutes = 45; $StatusStaleWarningMinutes = 5; $TimeoutMinutes = 180
    $FinalValidationTimeoutSeconds = 60; $script:WinRMTransport = 'Http'
    $script:LastProducerStatus = $null
    $history = @(
        [pscustomobject]@{ Phase = 4; PhaseName = 'Safe OS Phase'; StartedAtUtc = '2026-01-01T10:00:00Z'; Source = 'WindowsSetup.ExecutionLog' },
        [pscustomobject]@{ Phase = 5; PhaseName = 'First Boot Phase'; StartedAtUtc = '2026-01-01T10:00:16Z'; Source = 'WindowsSetup.ExecutionLog' }
    )
    $fixture.Queue.Enqueue([pscustomobject]@{
        RunId = 'loop-run'; Sequence = 10; Phase = 3; PhaseName = 'Downlevel Phase'; Status = 'InProgress'
        PercentComplete = 50; StatusUpdatedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-6).ToString('o')
        Mode = 'ActivePolling'; TargetBuild = '20348'
    })
    $fixture.Queue.Enqueue([pscustomobject]@{ Mode = 'Offline'; Status = 'Unknown'; Notes = 'No channel answered' })
    foreach ($mode in @('Heartbeat','ActivePolling')) {
        $fixture.Queue.Enqueue([pscustomobject]@{
            RunId = 'loop-run'; Sequence = 20; Phase = 7; PhaseName = 'Completed'; Status = 'Completed'
            PercentComplete = 100; StatusUpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            Mode = $mode; TargetBuild = '20348'; SetupPhaseHistory = $history
            LiveState = $(if ($mode -eq 'ActivePolling') { [pscustomobject]@{ CurrentBuild = '20348'; SystemSetupInProgress = 0; OOBEInProgress = 0 } } else { $null })
        })
    }
    . $monitorCode
    Assert-Condition ($finalOutcome -eq 'Completed' -and $fixture.Queue.Count -eq 0) 'Main loop must wait for live verification, then finish immediately'
    Assert-Condition (($fixture.Percentages -join ',') -eq '50,50,100' -and $status.PercentComplete -eq 100) 'Main loop lost cached progress or remained stuck below completion'
    Assert-Condition (@($fixture.Messages | Where-Object { $_ -like '*stale/unavailable*Downlevel*' }).Count -gt 0) 'Console did not report stale publication and its phase'
    Assert-Condition (@($fixture.Messages | Where-Object { $_ -like 'Validating update for a few seconds*' }).Count -eq 1) 'Final verification must show a single clean validation message'
    Assert-Condition (@($fixture.Messages | Where-Object { $_ -like '*Final validation pending*' }).Count -eq 0) 'Retry diagnostics must not clutter the console'
    Assert-Condition (@($fixture.Messages | Where-Object { $_ -like 'Confirmed Setup history: Safe OS Phase*' }).Count -eq 1) 'Missed Safe OS history must be printed exactly once'
    Assert-Condition (@($fixture.Messages | Where-Object { $_ -like 'Confirmed Setup history: First Boot Phase*' }).Count -eq 1) 'Missed First Boot history must be printed exactly once'

    $fixture.Messages = @(); $fixture.Percentages = @(); $fixture.Sleeps = 0; $script:LastProducerStatus = $null
    $fixture.Queue.Enqueue([pscustomobject]@{
        RunId = 'failed-run'; Sequence = 30; Phase = 3; PhaseName = 'Downlevel Phase'
        Status = 'Failed'; PercentComplete = 50; Mode = 'ActivePolling'
        Notes = "Setup interrupted at Downlevel Phase. Kindly check Panther logs."
    })
    . $monitorCode
    Assert-Condition ($finalOutcome -eq 'Failed' -and $fixture.Sleeps -eq 0) 'Main loop must stop immediately on target failure'
    Assert-Condition (@($fixture.Messages | Where-Object { $_ -like '*Status=Failed*Downlevel*Kindly check*' }).Count -eq 1) 'Main loop must report the failure stage and action, not just a frozen percentage'

    $TimeoutMinutes = 0
    . $monitorCode
    Assert-Condition ($finalOutcome -eq 'Timeout') 'Overall deadline must end an unverified run, not claim success'
    $script:ExpectedRunId = $null; $script:LastProducerStatus = $null
    'PASS: actual orchestrator loop reports stale/reset failures, replays missed phases once, verifies completion, and enforces timeout'
}

& {
    $tree = $syntaxTrees['Start-TargetUpgrade.ps1']
    $inventory = $tree.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.TryStatementAst] -and
            $_.Body.Extent.Text.Contains('$profileInventory = Get-UpgradeUserProfileInventory')
    } | Select-Object -First 1
    $compatibilityNotice = $tree.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.IfStatementAst] -and
            $_.Clauses[0].Item1.Extent.Text -eq '$SkipUserProfileCountCheck'
    } | Select-Object -First 1
    $gate = $tree.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.IfStatementAst] -and
            $_.Clauses[0].Item1.Extent.Text -eq '$hardFailures.Count -gt 0'
    } | Select-Object -First 1
    Assert-Condition ($inventory -and $compatibilityNotice -and $gate) 'Profile inventory, compatibility notice or aggregated precheck gate is missing'
    $checkCode = [scriptblock]::Create($tree.Extent.Text.Substring($compatibilityNotice.Extent.StartOffset, $inventory.Extent.EndOffset - $compatibilityNotice.Extent.StartOffset))
    $fixture = @{ Count = 0; FailRead = $false; FailCsv = $false; Reads = 0; State = @{}; Results = @(); Messages = @() }
    $script:LogDir = [IO.Path]::GetTempPath(); $script:RunStamp = 'offline-test'
    function Get-UpgradeUserProfileInventory {
        $fixture.Reads++
        if ($fixture.FailRead) { throw 'Profile inventory access denied' }
        [pscustomobject]@{
            UserProfileCount = $fixture.Count; TotalProfileCount = $fixture.Count + 3
            SpecialProfileCount = 3; LoadedUserProfileCount = 0
            Profiles = @([pscustomobject]@{ SID = 'test-user'; Special = $false })
        }
    }
    function Export-Csv {
        param($LiteralPath, [switch]$NoTypeInformation, $Encoding, $ErrorAction)
        process { if ($fixture.FailCsv) { throw 'Inventory CSV write denied' } }
    }
    function Set-UpgradeRegistryValue { param($Name, $Value, $Type) $fixture.State[$Name] = $Value }
    function Add-PreCheckResult {
        param($Name, $Result, $Detail)
        $fixture.Results += [pscustomobject]$PSBoundParameters
        if ($Result -eq 'FAIL') { $hardFailures.Add($Detail) }
    }
    function Set-Phase { param($Phase, $PhaseName, $Status, $PercentComplete, $ProgressSource, $ProgressFreshness, $Notes) }
    function Write-Log { param($Message, $Level) $fixture.Messages += $Message }
    foreach ($case in @(
        @{ Count = 0; Skip = $false; ReadError = $false; CsvError = $false },
        @{ Count = 24; Skip = $false; ReadError = $false; CsvError = $false },
        @{ Count = 25; Skip = $false; ReadError = $false; CsvError = $false },
        @{ Count = 26; Skip = $false; ReadError = $false; CsvError = $false },
        @{ Count = 1000; Skip = $false; ReadError = $false; CsvError = $false },
        @{ Count = 26; Skip = $true; ReadError = $false; CsvError = $false },
        @{ Count = 25; Skip = $true; ReadError = $false; CsvError = $false },
        @{ Count = 1000; Skip = $true; ReadError = $false; CsvError = $false },
        @{ Count = 26; Skip = $false; ReadError = $false; CsvError = $true },
        @{ Count = 25; Skip = $false; ReadError = $false; CsvError = $true },
        @{ Count = 0; Skip = $false; ReadError = $true; CsvError = $false },
        @{ Count = 0; Skip = $true; ReadError = $true; CsvError = $false }
    )) {
        $fixture.Count = $case.Count; $fixture.FailRead = $case.ReadError; $fixture.FailCsv = $case.CsvError
        $fixture.State = @{}; $fixture.Results = @(); $fixture.Messages = @()
        $hardFailures = [Collections.Generic.List[string]]::new()
        $SkipUserProfileCountCheck = $case.Skip
        $SkipOrphanedProfileCheck = $true
        $SkipPendingFileRenameCheck = $true
        $priorReads = $fixture.Reads
        . $checkCode
        Assert-Condition ($fixture.Results.Count -eq 1 -and $fixture.Results[0].Result -eq 'WARN') "Profile inventory must be warning-only: count=$($case.Count), legacy flag=$($case.Skip), read/csv errors=$($case.ReadError)/$($case.CsvError)"
        Assert-Condition (-not $fixture.State.ContainsKey('UserProfileCountLimit') -and -not $fixture.State.ContainsKey('UserProfileCountCheckStatus')) 'Warning-only inventory must not persist a profile gate or limit'
        Assert-Condition ($fixture.Reads -eq $priorReads + 1) 'Inventory must still run with the legacy compatibility switch'
        if (-not $case.ReadError) {
            $expectedWarning = "Detected $($case.Count) user profiles on the target server. Systems with a higher number of user profiles may experience increased upgrade time due to additional profile migration and processing activities during setup."
            Assert-Condition ($fixture.Results[0].Detail.StartsWith($expectedWarning)) 'Profile warning does not match the requested wording and actual count'
            Assert-Condition ($fixture.State.UserProfileCount -eq $case.Count -and $fixture.State.TotalProfileCount -eq $case.Count + 3) 'Warning must use non-special user count while still reporting the total inventory'
            Assert-Condition ($fixture.State.UserProfileInventoryStatus -eq 'Collected') 'Collected profile count must remain available even if CSV creation fails'
        } else {
            Assert-Condition (-not $fixture.State.ContainsKey('UserProfileCount')) 'Unknown profile count must not be published as zero'
            Assert-Condition ($fixture.State.UserProfileInventoryStatus -eq 'Unavailable' -and $fixture.Results[0].Detail -like '*Profile inventory access denied*') 'Inventory errors must remain explicit without blocking'
        }
        $blocked = $false
        try { . ([scriptblock]::Create($gate.Extent.Text)) } catch { $blocked = $true }
        Assert-Condition (-not $blocked -and $hardFailures.Count -eq 0) 'Profile count or inventory warning must not halt the upgrade'
        Assert-Condition (@($fixture.Messages | Where-Object { $_ -like 'UPGRADE BLOCKED:*' }).Count -eq 0) 'Profile counting must not display a blocking banner'
        Assert-Condition (@($fixture.Messages | Where-Object { $_ -like '-SkipUserProfileCountCheck is deprecated*' }).Count -eq [int]$case.Skip) 'Legacy switch must be explicitly reported as unnecessary, not suppress inventory'
        $hardFailures.Add('Independent safety check failed')
        $blocked = $false
        try { . ([scriptblock]::Create($gate.Extent.Text)) } catch { $blocked = $true }
        Assert-Condition $blocked 'Making profile inventory warning-only must not disable other precheck failures'
    }
    'PASS: exact warning for 0/24/25/26/1000 profiles, no count-related blocking, compatibility switch, inventory errors, and independent safety gates'
}

& {
    . (Get-TestFunction $syntaxTrees['OSUpgradeStatus.ps1'] 'Get-UpgradePendingRebootState')
    $tree = $syntaxTrees['Start-TargetUpgrade.ps1']
    $check = $tree.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.TryStatementAst] -and
            $_.Body.Extent.Text.Contains('$pendingReboot = Get-UpgradePendingRebootState')
    } | Select-Object -First 1
    $fixture = @{ Queue = @('\??\C:\installer.tmp', ''); PendingKey = ''; Result = $null; State = @{} }
    function Test-Path { param($Path, $ErrorAction) return ($Path -eq $fixture.PendingKey) }
    function Get-ItemProperty { param($Path, $ErrorAction) [pscustomobject]@{ PendingFileRenameOperations = $fixture.Queue } }
    function Set-UpgradeRegistryValue { param($Name, $Value, $Type) $fixture.State[$Name] = $Value }
    function Add-PreCheckResult { param($Name, $Result, $Detail) $fixture.Result = [pscustomobject]$PSBoundParameters }
    function Write-Log { param($Message, $Level) }
    $SkipPendingFileRenameCheck = $false
    . ([scriptblock]::Create($check.Extent.Text))
    Assert-Condition ($fixture.Result.Result -eq 'FAIL' -and $fixture.State.PendingFileRenameCheckStatus -eq 'Failed') 'Default rename gate must remain blocking'
    $SkipPendingFileRenameCheck = $true
    . ([scriptblock]::Create($check.Extent.Text))
    Assert-Condition ($fixture.Result.Result -eq 'WARN' -and $fixture.State.PendingFileRenameCheckStatus -eq 'Skipped' -and $fixture.Result.Detail -like '*BYPASSED*') 'Full upgrade precheck must explicitly record the rename-only bypass'
    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )) {
        $fixture.PendingKey = $key
        . ([scriptblock]::Create($check.Extent.Text))
        Assert-Condition ($fixture.Result.Result -eq 'FAIL' -and $fixture.State.PendingFileRenameCheckStatus -eq 'Skipped') 'CBS/WU must block the full upgrade even with rename bypass'
    }
    'PASS: actual target reboot check preserves CBS/WU blocking and persists an explicit narrow bypass'
}

& {
    $tree = $syntaxTrees['Start-TargetUpgrade.ps1']
    $backupLoop = $tree.Find({
        param($node)
        $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
            $node.Variable.VariablePath.UserPath -eq 'hive'
    }, $true)
    Assert-Condition ($null -ne $backupLoop) 'Registry backup loop missing'
    $fixture = @{ Calls = @(); Logs = @(); FailDefault = $false }
    $regBackupDir = Join-Path ([IO.Path]::GetTempPath()) 'OfflineRegistryBackup'
    function reg.exe {
        param($Verb, $Hive, $Destination, $Overwrite)
        $fixture.Calls += [pscustomobject]@{ Verb = $Verb; Hive = $Hive; Destination = $Destination; Overwrite = $Overwrite }
        $global:LASTEXITCODE = if ($fixture.FailDefault -and $Hive -eq 'HKU\.DEFAULT') { 5 } else { 0 }
    }
    function Write-Log { param($Message, $Level) $fixture.Logs += [pscustomobject]@{ Message = $Message; Level = $Level } }
    . ([scriptblock]::Create($backupLoop.Extent.Text))
    Assert-Condition (($fixture.Calls.Hive -join ',') -eq 'HKLM\SYSTEM,HKLM\SOFTWARE,HKLM\SAM,HKLM\SECURITY,HKU\.DEFAULT') 'Backup must retain existing hives and add exactly HKU\.DEFAULT'
    Assert-Condition ($fixture.Calls[-1].Destination -eq (Join-Path $regBackupDir 'HKU_.DEFAULT.hiv')) 'Default-user hive backup has the wrong output filename'
    Assert-Condition (@($fixture.Calls | Where-Object { $_.Verb -ne 'save' -or $_.Overwrite -ne '/y' }).Count -eq 0) 'Hive backup must only save, never export/restore/delete'
    $fixture.FailDefault = $true; $fixture.Logs = @()
    . ([scriptblock]::Create($backupLoop.Extent.Text))
    Assert-Condition (@($fixture.Logs | Where-Object { $_.Level -eq 'WARN' -and $_.Message -like '*exit code 5*HKU\.DEFAULT*' }).Count -eq 1) 'Default-user save failure must be explicit'
    Assert-Condition (@($fixture.Logs | Where-Object { $_.Message -like 'Registry hive saved: HKU\.DEFAULT*' }).Count -eq 0) 'A failed default-user save must not be reported as successful'
    $global:LASTEXITCODE = 0

    $dismCalls = @($tree.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Dism.exe'
    }, $true))
    $sfcCalls = @($tree.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'sfc.exe'
    }, $true))
    Assert-Condition ($dismCalls.Count -eq 1 -and $dismCalls[0].Extent.Text -match '/ScanHealth' -and $dismCalls[0].Extent.Text -notmatch '/RestoreHealth') 'Script must not launch a DISM repair'
    Assert-Condition ($sfcCalls.Count -eq 1 -and $dismCalls[0].Extent.StartOffset -lt $sfcCalls[0].Extent.StartOffset) 'Read-only DISM scan must remain before SFC, not a new repair after it'
    'PASS: exact HKU_.DEFAULT.hiv backup, native-command failure reporting, and unchanged DISM-before-SFC scan order'
}

& {
    $tree = $syntaxTrees['Start-RemoteUpgradeOrchestrator.ps1']
    foreach ($name in @('Get-UpgradeCompletionCheck','Add-UpgradeObservation','Wait-UpgradeCompletion')) {
        . (Get-TestFunction $tree $name)
    }
    $script:ExpectedRunId = 'validation-run'
    $fixture = @{
        Queue = [Collections.Generic.Queue[object]]::new(); Console = @(); Log = @()
        Calls = @(); Progress = @(); Mirror = $null; RealSleep = $false; Fallback = $null
    }
    function New-ValidationRecord {
        param([string]$Build = '20348', [string]$Status = 'Completed')
        [pscustomobject]@{
            RunId = 'validation-run'; Sequence = 10; Phase = 7; PhaseName = 'Completed'
            Status = $Status; PercentComplete = 100; TargetBuild = '20348'
            Notes = $null
            Mode = 'ActivePolling'; PingOk = $false; WinRmOk = $true
            LiveState = [pscustomobject]@{ CurrentBuild = $Build; SystemSetupInProgress = 0; OOBEInProgress = 0 }
        }
    }
    function Write-Log {
        param($Message, $Level, [switch]$LogOnly)
        $fixture.Log += $Message
        if (-not $LogOnly) { $fixture.Console += [pscustomobject]@{ Message = $Message; Level = $Level } }
    }
    function Write-LocalStatusMirror {
        param($ProducerStatus, $ObservationStatus, $ObservationError)
        if ($ProducerStatus) { $script:LastProducerStatus = $ProducerStatus }
        $fixture.Mirror = [pscustomobject]@{ Observation = $ObservationStatus; Error = $ObservationError }
    }
    function Write-Progress { param($Activity, $Status, $PercentComplete) $fixture.Progress += $Status }
    function Start-Sleep {
        param($Milliseconds)
        if ($fixture.RealSleep) { Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $Milliseconds }
    }
    function Get-RemoteUpgradeObservation {
        param($ComputerName, $Cred, $Transport, $TimeoutSec, [ref]$ErrorDetail)
        $fixture.Calls += [pscustomobject]$PSBoundParameters
        $response = if ($fixture.Queue.Count) { $fixture.Queue.Dequeue() } else { $fixture.Fallback }
        if ($response -is [string]) { $ErrorDetail.Value = $response; return $null }
        if ($response) { [pscustomobject]@{ ProducerStatus = $response; LiveState = $response.LiveState } }
    }
    function Reset-ValidationFixture {
        $fixture.Queue.Clear(); $fixture.Console = @(); $fixture.Log = @(); $fixture.Calls = @()
        $fixture.Progress = @(); $fixture.Mirror = $null; $fixture.RealSleep = $false; $fixture.Fallback = $null
        $script:LastProducerStatus = $null
    }
    $credential = [pscredential]::new('test-user', (ConvertTo-SecureString 'test-placeholder' -AsPlainText -Force))
    Reset-ValidationFixture
    $result = Wait-UpgradeCompletion -InitialStatus (New-ValidationRecord) -ComputerName 'mock-target' -Transport Http -TargetBuild '20348'
    Assert-Condition ($result.Outcome -eq 'Completed' -and $fixture.Calls.Count -eq 0) 'Already-verified completion must not add an unnecessary delay or probe'
    foreach ($withCredential in @($false, $true)) {
        Reset-ValidationFixture
        $fixture.Queue.Enqueue("Transient live OS query error")
        $fixture.Queue.Enqueue((New-ValidationRecord -Status CompletedWithWarnings))
        $params = @{ InitialStatus = (New-ValidationRecord -Build '17763'); ComputerName = 'mock-target'; Transport = 'Https'; TargetBuild = '20348' }
        if ($withCredential) { $params['Cred'] = $credential }
        $result = Wait-UpgradeCompletion @params
        Assert-Condition ($result.Outcome -eq 'CompletedWithWarnings' -and $fixture.Calls.Count -eq 2) 'Temporary query/build lag must recover and retain validation warnings'
        Assert-Condition ($fixture.Console.Count -eq 1 -and $fixture.Console[0].Message -like 'Validating update for a few seconds*') 'Validation retries must show one informational message, not repeated warnings'
        Assert-Condition (@($fixture.Log | Where-Object { $_ -like '*Transient live OS query error*' }).Count -eq 1) 'Quiet validation must still log diagnostic details'
        Assert-Condition (@($fixture.Progress | Where-Object { $_ -like 'Validating update*' }).Count -gt 0) 'Validation wait must remain visible in the progress UI'
        Assert-Condition ([bool]$fixture.Calls[-1].Cred -eq $withCredential -and $fixture.Calls[-1].Transport -eq 'Https') 'Final retry must preserve authentication and HTTPS'
        Assert-Condition ($fixture.Mirror.Observation.Status -eq 'CompletedWithWarnings') 'Recovered verification must update the status mirror'
    }
    foreach ($failureCase in @('NoResponse','WrongBuild','MissingFlags','WrongRun')) {
        Reset-ValidationFixture
        $fixture.RealSleep = $true
        $initial = New-ValidationRecord
        $initial.LiveState = $null
        $fixture.Fallback = switch ($failureCase) {
            'NoResponse' { 'Timed out querying live OS' }
            'WrongBuild' { New-ValidationRecord -Build '17763' }
            'MissingFlags' { $record = New-ValidationRecord; $record.LiveState.OOBEInProgress = $null; $record }
            'WrongRun' { $record = New-ValidationRecord; $record.RunId = 'unrelated-run'; $record }
        }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result = Wait-UpgradeCompletion -InitialStatus $initial -ComputerName 'mock-target' -Transport Http -TargetBuild '20348' -TimeoutSeconds 2
        $watch.Stop()
        Assert-Condition ($result.Outcome -eq 'ValidationFailed' -and $result.Error -like '*success is NOT being assumed*') "$failureCase must end in explicit unverified failure"
        Assert-Condition ($watch.Elapsed.TotalSeconds -lt 4 -and $fixture.Calls.Count -ge 1) "$failureCase did not respect the short verification deadline"
        Assert-Condition ($fixture.Calls[0].TimeoutSec -le 2) 'A single final-verification probe must not exceed the remaining budget'
        Assert-Condition ($fixture.Console.Count -eq 1 -and $fixture.Mirror.Observation.Mode -eq 'ValidationFailed') 'Final validation failure must be persisted without console retry spam'
        Assert-Condition ($script:LastProducerStatus.Status -eq 'Completed') 'Observer validation failure must not rewrite the target producer status'
    }
    Reset-ValidationFixture
    $failed = New-ValidationRecord -Status Failed
    $failed.Phase = 99; $failed.Notes = 'Rollback during verification'
    $fixture.Queue.Enqueue($failed)
    $initial = New-ValidationRecord; $initial.LiveState = $null
    $result = Wait-UpgradeCompletion -InitialStatus $initial -ComputerName 'mock-target' -Transport Http -TargetBuild '20348'
    Assert-Condition ($result.Outcome -eq 'Failed' -and $result.Error -like '*Rollback*') 'A target rollback must override completion during the grace period'
    $script:ExpectedRunId = $null; $script:LastProducerStatus = $null
    'PASS: quiet bounded final validation, immediate/transient success, credentials, incomplete evidence, wrong runs and rollback'
}

& {
    $tree = $syntaxTrees['Start-RemoteUpgradeOrchestrator.ps1']
    $summarySwitch = $tree.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.SwitchStatementAst] -and $_.Condition.Extent.Text -eq '$finalOutcome'
    } | Select-Object -First 1
    $path = Join-Path ([IO.Path]::GetTempPath()) ('UpgradeValidationExit_' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        $preamble = @'
$finalOutcome = 'ValidationFailed'
$finalValidationError = 'Live OS validation remained unavailable; check the target.'
function Write-FinalSummary { param($UpgradeStatus) Write-Output $UpgradeStatus }
function Write-Log { param($Message, $Level) Write-Output "$Level : $Message" }
'@
        [IO.File]::WriteAllText($path, $preamble + [Environment]::NewLine + $summarySwitch.Extent.Text)
        $output = & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $path
        Assert-Condition ($LASTEXITCODE -eq 3 -and ($output -join ' ') -like '*ERROR*validation unconfirmed*') 'Unverified final validation must print an error and exit 3'
        Assert-Condition (($output -join ' ') -notlike '*Success*') 'Unverified final validation must not print a success summary'
    } finally {
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    }
    $global:LASTEXITCODE = 0
    'PASS: actual final-summary branch exits 3 with an explicit validation error'
}

& {
    . (Get-TestFunction $syntaxTrees['Start-RemoteUpgradeOrchestrator.ps1'] 'Write-Log')
    $fixture = @{ Console = @() }
    function Write-Host { param($Object, $ForegroundColor) $fixture.Console += $Object }
    $script:LocalLogFile = Join-Path ([IO.Path]::GetTempPath()) ('UpgradeQuietLog_' + [guid]::NewGuid().ToString('N') + '.log')
    try {
        Write-Log 'Validating update for a few seconds...'
        Write-Log 'Transient verification error retained for diagnostics' -Level WARN -LogOnly
        $lines = @(Get-Content -LiteralPath $script:LocalLogFile)
        Assert-Condition ($fixture.Console.Count -eq 1 -and $lines.Count -eq 2) 'Quiet retry logging must retain file diagnostics without printing another console line'
        Assert-Condition ($lines[1] -like '*[WARN]*Transient verification error*') 'Quiet log lost the warning and its diagnostic text'
    } finally {
        if ([IO.File]::Exists($script:LocalLogFile)) { [IO.File]::Delete($script:LocalLogFile) }
    }
    'PASS: real log writer keeps retry diagnostics on disk without console noise'
}

"PASS: all $($syntaxTrees.Count) PowerShell files parse; no upgrades, network calls or registry writes performed"