[CmdletBinding()]
param()

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
        Assert-Condition (($result.Operations.Action -join ',') -eq $case.Actions) 'Wrong operation parsing'
    }
    $fixture.Queue = $null
    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )) {
        $fixture.PendingKey = $key
        Assert-Condition (Get-UpgradePendingRebootState).RebootPending 'Servicing gate lost'
    }
    $fixture.RegistryFailure = $true
    $failed = $false
    try { Get-UpgradePendingRebootState | Out-Null } catch { $failed = $true }
    Assert-Condition $failed 'Unreadable registry must fail closed'
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
    . (Get-TestFunction $syntaxTrees['Start-RemoteUpgradeOrchestrator.ps1'] 'Read-RemoteStatusJsonViaWinRM')
    $fixture = @{ Invoke = $null; TimedOut = $false; Removed = 0 }
    function Invoke-Command {
        param($ComputerName, $Credential, [switch]$UseSSL, $Port, $SessionOption, $ScriptBlock, $ArgumentList, $ErrorAction)
        $fixture.Invoke = $PSBoundParameters
        return '{"Phase":1,"PercentComplete":2}'
    }
    function New-PSSessionOption { param([switch]$SkipCACheck, [switch]$SkipCNCheck, [switch]$SkipRevocationCheck) return 'SkipChecks' }
    function Start-Job { param($ScriptBlock, $ArgumentList) [pscustomobject]@{ Output = (& $ScriptBlock @ArgumentList) } }
    function Wait-Job { param($Job, $Timeout) if (-not $fixture.TimedOut) { return $Job } }
    function Receive-Job { param($Job, $ErrorVariable, $ErrorAction) return $Job.Output }
    function Stop-Job { param($Job, $ErrorAction) }
    function Remove-Job { param($Job, [switch]$Force, $ErrorAction) $fixture.Removed++ }
    $credential = [pscredential]::new('test-user', (ConvertTo-SecureString 'test-placeholder' -AsPlainText -Force))
    foreach ($transport in @('Http', 'Https', 'HttpsSkipCert')) {
        $detail = $null
        $raw = Read-RemoteStatusJsonViaWinRM -ComputerName 'mock-target' -Cred $credential -JsonPath 'D:\upgrade_status.json' -Transport $transport -ErrorDetail ([ref]$detail)
        Assert-Condition (($raw | ConvertFrom-Json).PercentComplete -eq 2) 'JSON reader lost data'
        Assert-Condition ($fixture.Invoke.Credential -eq $credential -and $fixture.Invoke.ComputerName -eq 'mock-target') 'Wrong connection identity'
        Assert-Condition ($fixture.Invoke.ArgumentList -eq 'D:\upgrade_status.json') 'Wrong remote path'
        Assert-Condition ([bool]$fixture.Invoke.UseSSL -eq ($transport -ne 'Http')) 'Wrong SSL setting'
        if ($transport -ne 'Http') { Assert-Condition ($fixture.Invoke.Port -eq 5986) 'Wrong HTTPS port' }
        Assert-Condition (($fixture.Invoke.SessionOption -eq 'SkipChecks') -eq ($transport -eq 'HttpsSkipCert')) 'Certificate checks changed unexpectedly'
    }
    $fixture.TimedOut = $true
    $raw = Read-RemoteStatusJsonViaWinRM -ComputerName 'mock-target' -JsonPath 'D:\upgrade_status.json' -Transport Http -ErrorDetail ([ref]$detail)
    Assert-Condition ($null -eq $raw -and $detail -like 'Timed out*' -and $fixture.Removed -eq 4) 'Timeout/cleanup failed'
    'PASS: WinRM transport, credentials, path, timeout and cleanup (mocked)'
}

& {
    $fixture = @{ Queue = @('\??\C:\installer.tmp', ''); Warning = ''; Connection = $null }
    function Test-Path { param($Path, $ErrorAction) return $false }
    function Get-ItemProperty { param($Path, $ErrorAction) [pscustomobject]@{ PendingFileRenameOperations = $fixture.Queue } }
    function Get-CimInstance { param($ClassName, $ErrorAction) [pscustomobject]@{ Caption = 'Test OS'; BuildNumber = '17763'; LastBootUpTime = [datetime]'2026-01-01' } }
    function Invoke-Command {
        param($ComputerName, $Credential, [switch]$UseSSL, $Port, $SessionOption, $ScriptBlock, [object[]]$ArgumentList, $ErrorAction)
        $fixture.Connection = $PSBoundParameters
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
    'PASS: read-only readiness command, reboot warning, boot metadata and HTTPS (mocked)'
}

"PASS: all $($syntaxTrees.Count) PowerShell files parse; no upgrades, network calls or registry writes performed"