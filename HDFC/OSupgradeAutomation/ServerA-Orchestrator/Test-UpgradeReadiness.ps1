<#
.SYNOPSIS
    Read-only pending-reboot diagnostics over WinRM; does not start an upgrade.
.DESCRIPTION
    Run before the full orchestrator to inspect reboot flags and queued file
    operations without running DISM, SFC, backup, staging, or Setup. This is a
    quick reboot-gate check, not a substitute for the full upgrade prechecks.
.PARAMETER Credential
    Optional target credentials. When supplied, WinRM explicitly uses Negotiate
    authentication, matching the orchestrator. Without credentials, existing
    current-user authentication behavior is retained.
.PARAMETER SkipPendingFileRenameCheck
    Bypass only the pending-file-rename gate while retaining the detected
    operations in the report. CBS and Windows Update reboot gates still block.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetComputer,
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$UseSSL,
    [switch]$SkipCertificateCheck,
    [switch]$SkipPendingFileRenameCheck
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\ServerB-Target\OSUpgradeStatus.ps1')
$invokeParams = @{ ComputerName = $TargetComputer; ErrorAction = 'Stop' }
if ($Credential) {
    $invokeParams['Credential'] = $Credential
    $invokeParams['Authentication'] = 'Negotiate'
}
if ($UseSSL -or $SkipCertificateCheck) {
    $invokeParams['UseSSL'] = $true
    $invokeParams['Port'] = 5986
}
if ($SkipCertificateCheck) {
    $invokeParams['SessionOption'] = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
}
$result = Invoke-Command @invokeParams -ScriptBlock {
    param($PendingCheckDefinition, [bool]$SkipPendingRenames)
    $pending = & ([scriptblock]::Create($PendingCheckDefinition)) -SkipPendingFileRenameCheck:$SkipPendingRenames
    $system = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        OS = $system.Caption
        Build = $system.BuildNumber
        LastBootUpTime = $system.LastBootUpTime
        RebootPending = $pending.RebootPending
        UpgradeBlocked = $pending.UpgradeBlocked
        CBSRebootPending = $pending.CBSRebootPending
        WindowsUpdateRebootRequired = $pending.WindowsUpdateRebootRequired
        PendingFileRenameCheckSkipped = $pending.PendingFileRenameCheckSkipped
        PendingFileRenameOperationsPresent = $pending.PendingFileRenameOperationsPresent
        Operations = @($pending.Operations)
        Reasons = @($pending.Reasons)
        BlockingReasons = @($pending.BlockingReasons)
    }
} -ArgumentList ${function:Get-UpgradePendingRebootState}.ToString(), ([bool]$SkipPendingFileRenameCheck)

$result | Format-List ComputerName, OS, Build, LastBootUpTime, RebootPending, UpgradeBlocked, CBSRebootPending, WindowsUpdateRebootRequired, PendingFileRenameCheckSkipped | Out-Host
if ($result.Operations.Count -gt 0) {
    $result.Operations | Format-Table Action, Source, Destination -Wrap -AutoSize | Out-Host
}
if ($result.PendingFileRenameCheckSkipped) {
    Write-Warning 'PendingFileRenameOperations gate BYPASSED explicitly; detected operations are still listed and remain unchanged. CBS and Windows Update reboot gates are not bypassed.'
}
if ($result.UpgradeBlocked) {
    Write-Warning 'Upgrade reboot gate is BLOCKED. Complete the servicing/installer work and an approved reboot, then run this check again. Do not delete the pending-operation registry values.'
} elseif ($result.PendingFileRenameCheckSkipped) {
    Write-Host 'No remaining blocker in this reboot check after the explicit file-rename bypass. This is not a clean-reboot verdict; full upgrade prechecks are still required.'
} else {
    Write-Host 'No pending reboot found by this check. Full upgrade prechecks are still required.'
}
$result