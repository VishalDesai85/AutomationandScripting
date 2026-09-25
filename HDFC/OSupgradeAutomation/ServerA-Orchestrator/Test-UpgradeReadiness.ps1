<#
.SYNOPSIS
    Read-only pending-reboot diagnostics over WinRM; does not start an upgrade.
.DESCRIPTION
    Run before the full orchestrator to inspect reboot flags and queued file
    operations without running DISM, SFC, backup, staging, or Setup. This is a
    quick reboot-gate check, not a substitute for the full upgrade prechecks.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetComputer,
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$UseSSL,
    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\ServerB-Target\OSUpgradeStatus.ps1')
$invokeParams = @{ ComputerName = $TargetComputer; ErrorAction = 'Stop' }
if ($Credential) { $invokeParams['Credential'] = $Credential }
if ($UseSSL -or $SkipCertificateCheck) {
    $invokeParams['UseSSL'] = $true
    $invokeParams['Port'] = 5986
}
if ($SkipCertificateCheck) {
    $invokeParams['SessionOption'] = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
}
$result = Invoke-Command @invokeParams -ScriptBlock {
    param($PendingCheckDefinition)
    $pending = & ([scriptblock]::Create($PendingCheckDefinition))
    $system = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        OS = $system.Caption
        Build = $system.BuildNumber
        LastBootUpTime = $system.LastBootUpTime
        RebootPending = $pending.RebootPending
        CBSRebootPending = $pending.CBSRebootPending
        WindowsUpdateRebootRequired = $pending.WindowsUpdateRebootRequired
        Operations = @($pending.Operations)
        Reasons = @($pending.Reasons)
    }
} -ArgumentList ${function:Get-UpgradePendingRebootState}.ToString()

$result | Format-List ComputerName, OS, Build, LastBootUpTime, RebootPending, CBSRebootPending, WindowsUpdateRebootRequired | Out-Host
if ($result.Operations.Count -gt 0) {
    $result.Operations | Format-Table Action, Source, Destination -Wrap -AutoSize | Out-Host
}
if ($result.RebootPending) {
    Write-Warning 'Upgrade reboot gate is BLOCKED. Complete the servicing/installer work and an approved reboot, then run this check again. Do not delete the pending-operation registry values.'
} else {
    Write-Host 'No pending reboot found by this check. Full upgrade prechecks are still required.'
}
$result