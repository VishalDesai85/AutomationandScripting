#requires -Version 5.1
. (Join-Path $PSScriptRoot 'New-HyperVLab-Configured.ps1')

function Get-VMProcessor {
    [CmdletBinding()]
    param($VMName)
    throw 'Get-VMProcessor must be mocked.'
}

function Get-VM {
    [CmdletBinding()]
    param($Name)
    throw 'Get-VM must be mocked.'
}

function Start-VM {
    [CmdletBinding()]
    param($VM)
    throw 'Start-VM must be mocked.'
}

Describe 'Guest hypervisor boot configuration' {
    BeforeEach {
        $script:launchType = 1
        $script:bcdFailure = ''
        $script:retainOldValue = $false
        $script:bcdStore = New-CimInstance -Namespace 'root\WMI' -ClassName BcdStore -ClientOnly
        $script:bcdLoader = New-CimInstance -Namespace 'root\WMI' -ClassName BcdObject -ClientOnly
        Mock Invoke-CimMethod {
            switch ($MethodName) {
                'OpenStore' {
                    if ($script:bcdFailure -eq $MethodName) {
                        return [pscustomobject]@{ ReturnValue = $false }
                    }
                    return [pscustomobject]@{ ReturnValue = $true; Store = $script:bcdStore }
                }
                'OpenObject' {
                    if ($script:bcdFailure -eq $MethodName) {
                        return [pscustomobject]@{ ReturnValue = $false }
                    }
                    return [pscustomobject]@{ ReturnValue = $true; Object = $script:bcdLoader }
                }
                'EnumerateElements' {
                    if ($script:bcdFailure -eq $MethodName) {
                        return [pscustomobject]@{ ReturnValue = $false }
                    }
                    $elements = @([pscustomobject]@{ Type = 0x22000002; String = '\Windows' })
                    if ($null -ne $script:launchType) {
                        $elements += [pscustomobject]@{ Type = 0x250000F0; Integer = $script:launchType }
                    }
                    return [pscustomobject]@{ ReturnValue = $true; Elements = $elements }
                }
                'SetIntegerElement' {
                    if ($script:bcdFailure -eq $MethodName) {
                        return [pscustomobject]@{ ReturnValue = $false }
                    }
                    if (-not $script:retainOldValue) { $script:launchType = $Arguments.Integer }
                    return [pscustomobject]@{ ReturnValue = $true }
                }
                default { throw "Unexpected BCD method '$MethodName'." }
            }
        }
    }

    It 'leaves an explicit Auto setting unchanged' {
        $state = & $script:LabGuestHypervisorBootConfiguration $true
        $state.HypervisorLaunchType | Should Be 'Auto'
        $state.Changed | Should Be $false
        Assert-MockCalled Invoke-CimMethod -Times 0 -Exactly -Scope It -ParameterFilter {
            $MethodName -eq 'SetIntegerElement'
        }
    }

    It 'sets a missing launch setting to Auto and verifies the write' {
        $script:launchType = $null
        $state = & $script:LabGuestHypervisorBootConfiguration $true
        $state.HypervisorLaunchType | Should Be 'Auto'
        $state.Changed | Should Be $true
        Assert-MockCalled Invoke-CimMethod -Times 1 -Exactly -Scope It -ParameterFilter {
            $MethodName -eq 'SetIntegerElement' -and
            $Arguments.Type -eq 0x250000F0 -and $Arguments.Integer -eq 1
        }
        Assert-MockCalled Invoke-CimMethod -Times 2 -Exactly -Scope It -ParameterFilter {
            $MethodName -eq 'EnumerateElements'
        }
    }

    It 'changes an explicit Off setting to Auto' {
        $script:launchType = 0
        $state = & $script:LabGuestHypervisorBootConfiguration $true
        $state.Changed | Should Be $true
        $script:launchType | Should Be 1
    }

    It 'rejects a missing setting during read-only verification without repairing it' {
        $script:launchType = $null
        { & $script:LabGuestHypervisorBootConfiguration $false } | Should Throw 'not Auto'
        Assert-MockCalled Invoke-CimMethod -Times 0 -Exactly -Scope It -ParameterFilter {
            $MethodName -eq 'SetIntegerElement'
        }
    }

    It 'targets the system store and current Windows loader rather than a default entry' {
        & $script:LabGuestHypervisorBootConfiguration $false
        Assert-MockCalled Invoke-CimMethod -Times 1 -Exactly -Scope It -ParameterFilter {
            $MethodName -eq 'OpenStore' -and $Namespace -eq 'root\WMI' -and
            $ClassName -eq 'BcdStore' -and $Arguments.File -eq ''
        }
        Assert-MockCalled Invoke-CimMethod -Times 1 -Exactly -Scope It -ParameterFilter {
            $MethodName -eq 'OpenObject' -and
            $Arguments.Id -eq '{fa926493-6f1c-4193-a414-58f0b2456d1e}'
        }
    }

    It 'surfaces failure to open the store' {
        $script:bcdFailure = 'OpenStore'
        { & $script:LabGuestHypervisorBootConfiguration $true } | Should Throw 'system BCD store'
    }

    It 'surfaces failure to open the current loader' {
        $script:bcdFailure = 'OpenObject'
        { & $script:LabGuestHypervisorBootConfiguration $true } | Should Throw 'current guest Windows boot loader'
    }

    It 'does not treat a failed enumeration as a missing setting' {
        $script:bcdFailure = 'EnumerateElements'
        { & $script:LabGuestHypervisorBootConfiguration $true } | Should Throw 'enumerate'
        Assert-MockCalled Invoke-CimMethod -Times 0 -Exactly -Scope It -ParameterFilter {
            $MethodName -eq 'SetIntegerElement'
        }
    }

    It 'rejects an unknown launch value without replacing it' {
        $script:launchType = 99
        { & $script:LabGuestHypervisorBootConfiguration $true } | Should Throw 'unexpected value'
    }

    It 'surfaces a failed BCD update' {
        $script:launchType = 0
        $script:bcdFailure = 'SetIntegerElement'
        { & $script:LabGuestHypervisorBootConfiguration $true } | Should Throw 'Could not set'
    }

    It 'rejects a successful provider response when Auto did not persist' {
        $script:launchType = 0
        $script:retainOldValue = $true
        { & $script:LabGuestHypervisorBootConfiguration $true } | Should Throw 'not Auto'
    }
}

Describe 'Nested virtualization deployment validation' {
    BeforeEach {
        $script:credential = [PSCredential]::new(
            'Administrator', (ConvertTo-SecureString 'test-only' -AsPlainText -Force))
        Mock Get-VMProcessor { [pscustomobject]@{ ExposeVirtualizationExtensions = $true } }
        Mock Invoke-Command { [pscustomobject]@{ HypervisorLaunchType = 'Auto'; Changed = $false } }
        Mock Restart-LabGuest {}
    }

    It 'does not restart a guest already configured for Auto' {
        Enable-LabGuestHypervisor -VMName 'TestNode01' -Credential $script:credential
        Assert-MockCalled Restart-LabGuest -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-Command -Times 1 -Exactly -Scope It -ParameterFilter {
            $VMName -eq 'TestNode01' -and $ArgumentList[0] -eq $true
        }
    }

    It 'restarts only the changed guest and verifies its setting afterward' {
        Mock Invoke-Command {
            [pscustomobject]@{ HypervisorLaunchType = 'Auto'; Changed = [bool]$ArgumentList[0] }
        }
        Enable-LabGuestHypervisor -VMName 'TestNode01' -Credential $script:credential -TimeoutSeconds 123
        Assert-MockCalled Restart-LabGuest -Times 1 -Exactly -Scope It -ParameterFilter {
            $VMName -eq 'TestNode01' -and $Credential -eq $script:credential -and
            $RestartCredential -eq $script:credential -and $TimeoutSeconds -eq 123
        }
        Assert-MockCalled Invoke-Command -Times 1 -Exactly -Scope It -ParameterFilter {
            $VMName -eq 'TestNode01' -and $ArgumentList[0] -eq $false
        }
    }

    It 'stops before entering a guest whose host exposure is disabled' {
        Mock Get-VMProcessor { [pscustomobject]@{ ExposeVirtualizationExtensions = $false } }
        { Enable-LabGuestHypervisor -VMName 'TestNode01' -Credential $script:credential } |
            Should Throw 'Shut down the VM'
        Assert-MockCalled Invoke-Command -Times 0 -Exactly -Scope It
        Assert-MockCalled Restart-LabGuest -Times 0 -Exactly -Scope It
    }

    It 'rejects ambiguous processor discovery' {
        Mock Get-VMProcessor {
            [pscustomobject]@{ ExposeVirtualizationExtensions = $true }
            [pscustomobject]@{ ExposeVirtualizationExtensions = $true }
        }
        { Enable-LabGuestHypervisor -VMName 'TestNode01' -Credential $script:credential } |
            Should Throw 'not verified'
    }

    It 'rejects an incomplete guest response without restarting' {
        Mock Invoke-Command { [pscustomobject]@{ HypervisorLaunchType = 'Auto' } }
        { Enable-LabGuestHypervisor -VMName 'TestNode01' -Credential $script:credential } |
            Should Throw 'Could not verify'
        Assert-MockCalled Restart-LabGuest -Times 0 -Exactly -Scope It
    }

    It 'does not report success when the post-restart setting is wrong' {
        Mock Invoke-Command {
            if ($ArgumentList[0]) {
                return [pscustomobject]@{ HypervisorLaunchType = 'Auto'; Changed = $true }
            }
            [pscustomobject]@{ HypervisorLaunchType = 'Off'; Changed = $false }
        }
        { Enable-LabGuestHypervisor -VMName 'TestNode01' -Credential $script:credential } |
            Should Throw 'did not remain Auto'
    }

    It 'surfaces restart failure without continuing verification' {
        Mock Invoke-Command { [pscustomobject]@{ HypervisorLaunchType = 'Auto'; Changed = $true } }
        Mock Restart-LabGuest { throw 'Restart verification timed out.' }
        { Enable-LabGuestHypervisor -VMName 'TestNode01' -Credential $script:credential } |
            Should Throw 'Restart verification timed out'
        Assert-MockCalled Invoke-Command -Times 1 -Exactly -Scope It
    }

    It 'does not enter or modify existing guests in WhatIf mode' {
        Mock Get-LabAVMAHostProfile { throw 'Host discovery must not run during existing-VM preview.' }
        Invoke-HyperVLabConfiguredProvisioning -ConfigureExistingVMName 'TestNode01' `
            -SubnetPrefix '10.151.33' -Gateway '10.151.33.1' -DnsServer '10.151.33.84' `
            -PrefixLength 24 -ManagementSwitchName 'Natswitch' -SmbSwitchName 'SMB-Network' -WhatIf
        Assert-MockCalled Get-VMProcessor -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-Command -Times 0 -Exactly -Scope It
        Assert-MockCalled Restart-LabGuest -Times 0 -Exactly -Scope It
    }
}

Describe 'Guest hypervisor validation in the configured workflow' {
    BeforeEach {
        $credential = [PSCredential]::new(
            'Administrator', (ConvertTo-SecureString 'test-only' -AsPlainText -Force))
        $script:settings = @{
            NamePrefix = 'TestNode'
            DomainName = 'mylab.local'
            DomainControllerVMName = 'AD01'
            SubnetPrefix = '10.151.33'
            PrefixLength = 24
            Gateway = '10.151.33.1'
            DnsServer = '10.151.33.84'
            ManagementSwitchName = 'Natswitch'
            SmbSwitchName = 'SMB-Network'
            PowerShellDirectTimeoutSeconds = 123
            LocalAdministratorCredential = $credential
            DomainCredential = $credential
        }
        $script:steps = [Collections.Generic.List[string]]::new()
        Mock Get-LabAVMAHostProfile {
            [pscustomobject]@{ Caption = 'Test Server'; EditionID = 'ServerDatacenter'; LicenseStatus = 1 }
        }
        Mock Test-LabDomainController {}
        Mock Invoke-HyperVLabProvisioning { [pscustomobject]@{ Name = 'TestNode01' } }
        Mock Get-VM { [pscustomobject]@{ Name = 'TestNode01'; State = 'Off' } }
        Mock Start-VM {}
        Mock Wait-LabPowerShellDirect { $script:steps.Add('Wait') }
        Mock Enable-LabGuestHypervisor { $script:steps.Add('Hypervisor') }
        Mock Disable-LabGuestFirewall { $script:steps.Add('Firewall') }
        Mock Set-LabGuestTimeZone {}
        Mock Get-LabAvailableIPv4Addresses { '10.151.33.2' }
        Mock New-LabSerializedOU { [pscustomobject]@{ Name = 'TestNodeOU'; DistinguishedName = 'OU=TestNodeOU,DC=mylab,DC=local' } }
        Mock Get-LabGuestAdapterPlan { [pscustomobject]@{ Name = 'NAT1' } }
        Mock Invoke-LabGuestNetworkConfiguration { $script:steps.Add('Network') }
        Mock Join-LabGuestDomain { [pscustomobject]@{ Domain = 'mylab.local' } }
        Mock Invoke-LabGuestAVMA {
            [pscustomobject]@{ Status = 'AlreadyActivated'; Reason = 'Test'; LicenseStatus = 1 }
        }
    }

    It 'validates new guests before networking and preserves the completion summary' {
        $result = Invoke-HyperVLabConfiguredProvisioning @script:settings
        ($script:steps -join ',') | Should Be 'Wait,Hypervisor,Firewall,Network'
        $result.VMName | Should Be 'TestNode01'
        $result.Domain | Should Be 'mylab.local'
        $result.ActivationStatus | Should Be 'AlreadyActivated'
        Assert-MockCalled Enable-LabGuestHypervisor -Times 1 -Exactly -Scope It -ParameterFilter {
            $VMName -eq 'TestNode01' -and $TimeoutSeconds -eq 123
        }
    }

    It 'also validates explicitly resumed guests' {
        Invoke-HyperVLabConfiguredProvisioning @script:settings -ConfigureExistingVMName 'TestNode01'
        ($script:steps -join ',') | Should Be 'Wait,Hypervisor,Firewall,Network'
        Assert-MockCalled Invoke-HyperVLabProvisioning -Times 0 -Exactly -Scope It
        Assert-MockCalled Start-VM -Times 1 -Exactly -Scope It
        Assert-MockCalled Enable-LabGuestHypervisor -Times 1 -Exactly -Scope It
    }

    It 'stops configuration before networking or OU creation when boot validation fails' {
        Mock Enable-LabGuestHypervisor { throw 'Guest BCD verification failed.' }
        { Invoke-HyperVLabConfiguredProvisioning @script:settings } |
            Should Throw 'Post-provisioning configuration stopped'
        Assert-MockCalled Get-LabAvailableIPv4Addresses -Times 0 -Exactly -Scope It
        Assert-MockCalled New-LabSerializedOU -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-LabGuestNetworkConfiguration -Times 0 -Exactly -Scope It
    }

    It 'does not discover or enter guests during a new-deployment preview' {
        Invoke-HyperVLabConfiguredProvisioning @script:settings -WhatIf
        Assert-MockCalled Get-LabAVMAHostProfile -Times 0 -Exactly -Scope It
        Assert-MockCalled Wait-LabPowerShellDirect -Times 0 -Exactly -Scope It
        Assert-MockCalled Enable-LabGuestHypervisor -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-HyperVLabProvisioning -Times 1 -Exactly -Scope It
    }
}
