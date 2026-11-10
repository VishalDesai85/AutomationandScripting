#requires -Version 5.1
<#
.SYNOPSIS
Single menu entry point for creating or cleaning up Hyper-V lab nodes.
.EXAMPLE
.\Manage-HyperVLab.ps1
.EXAMPLE
.\Manage-HyperVLab.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$VMRoot = 'D:\HyperV',
    [string]$DomainControllerVMName
)

function Invoke-HyperVLabMenu {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$VMRoot = 'D:\HyperV', [string]$DomainControllerVMName)

    $ErrorActionPreference = 'Stop'
    Write-Host '1: Create and configure Hyper-V lab nodes'
    Write-Host '2: Clean up Hyper-V lab nodes'
    $scriptName = $null
    while (-not $scriptName) {
        switch (Read-Host 'Select 1 or 2') {
            '1' { $scriptName = 'New-HyperVLab-Configured.ps1' }
            '2' { $scriptName = 'Remove-HyperVLabNodes.ps1' }
            default { Write-Warning 'Select 1 or 2.' }
        }
    }
    $path = Join-Path $PSScriptRoot $scriptName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required script '$path' is missing. Keep the menu, configured provisioner and cleanup script together."
    }
    $arguments = @{ VMRoot = $VMRoot; WhatIf = [bool]$WhatIfPreference }
    if ($DomainControllerVMName) { $arguments['DomainControllerVMName'] = $DomainControllerVMName }
    if ($PSBoundParameters.ContainsKey('Confirm')) { $arguments['Confirm'] = $PSBoundParameters['Confirm'] }
    & $path @arguments
}

if ($MyInvocation.InvocationName -ne '.') {
    $PSBoundParameters['VMRoot'] = $VMRoot
    Invoke-HyperVLabMenu @PSBoundParameters
}
