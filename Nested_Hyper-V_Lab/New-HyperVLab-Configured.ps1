#requires -Version 5.1
<#
.SYNOPSIS
Provisions Hyper-V lab VMs, configures their guests, and activates eligible Windows Server guests with AVMA.
.DESCRIPTION
Uses PowerShell Direct from the Hyper-V host. Credentials are requested securely and
are never stored in this script. Verifies host virtualization exposure and enables
guest hypervisor startup, restarting changed guests before continuing configuration.
Does not install the Hyper-V role inside guests.
.EXAMPLE
.\New-HyperVLab-Configured.ps1
.EXAMPLE
.\New-HyperVLab-Configured.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$VMRoot = 'D:\HyperV',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]{0,12}$')]
    [string]$NamePrefix,
    [ValidatePattern('^[A-Za-z][A-Za-z0-9.-]*$')]
    [string]$DomainName = 'mylab.local',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]*$')]
    [string]$DomainControllerVMName = 'MylabAD01',
    [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,3}$')]
    [string]$SubnetPrefix = '10.151.33',
    [ValidateRange(24, 24)]
    [int]$PrefixLength = 24,
    [string]$Gateway = '10.151.33.1',
    [string]$DnsServer = '10.151.33.84',
    [string]$GuestTimeZone = 'India Standard Time',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]*$')]
    [string]$OUBaseName,
    [ValidatePattern('^[A-Za-z][A-Za-z0-9-]*$')]
    [string]$ExistingOUName,
    [string]$ManagementSwitchName = 'Natswitch',
    [string]$SmbSwitchName = 'SMB-Network',
    [ValidateRange(60, 3600)]
    [int]$PowerShellDirectTimeoutSeconds = 900,
    [string[]]$ConfigureExistingVMName,
    [PSCredential]$LocalAdministratorCredential,
    [PSCredential]$DomainCredential
)

# Embedded provisioning functions make this variant self-contained.
function Read-LabInteger {
    param(
        [string]$Prompt,
        [int]$Minimum,
        [int]$Maximum = [int]::MaxValue,
        [int]$Default
    )

    while ($true) {
        $text = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($text)) {
            $text = [string]$Default
        }
        $value = 0
        if ([int]::TryParse($text, [ref]$value) -and $value -ge $Minimum -and $value -le $Maximum) {
            return $value
        }
        Write-Warning "Enter a whole number from $Minimum to $Maximum."
    }
}

function Read-LabYesNo {
    param([string]$Prompt, [bool]$Default = $false)

    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $text = Read-Host "$Prompt [$hint]"
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $Default
        }
        switch -Regex ($text.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$' { return $false }
            default { Write-Warning 'Enter Y or N.' }
        }
    }
}

function ConvertTo-LabSizeBytes {
    param([string]$Text)

    if ($Text -notmatch '^\s*(\d+(?:\.\d+)?)\s*(GB|TB)\s*$') {
        throw 'Enter a positive size with GB or TB, for example 8GB, 1.5GB, or 1TB.'
    }
    $number = [decimal]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    $unit = if ($Matches[2] -ieq 'TB') { 1TB } else { 1GB }
    $bytes = $number * $unit
    if ($bytes -le 0 -or $bytes -gt [long]::MaxValue) {
        throw 'The requested size must be positive and fit in a 64-bit byte count.'
    }
    # Hyper-V memory is configured in whole MiB; round fractional MiB upward.
    return [long]([Math]::Ceiling($bytes / 1MB) * 1MB)
}

function Read-LabSize {
    param([string]$Prompt, [long]$Minimum, [long]$Maximum)

    while ($true) {
        $text = Read-Host "$Prompt (GB or TB)"
        try {
            $bytes = ConvertTo-LabSizeBytes -Text $text
            if ($bytes -lt $Minimum -or $bytes -gt $Maximum) {
                throw "Size must be between $($Minimum / 1GB)GB and $($Maximum / 1GB)GB."
            }
            return $bytes
        }
        catch {
            Write-Warning $_.Exception.Message
        }
    }
}

function Read-LabMemorySettings {
    param([string]$Target, [long]$HostMemoryCapacity)

    Write-Host "`nMemory assignment for ${Target}: 1 = fixed, 2 = dynamic"
    $memoryMode = Read-LabInteger -Prompt "Memory type for $Target" -Minimum 1 -Maximum 2 -Default 1
    if ($memoryMode -eq 1) {
        $memory = Read-LabSize -Prompt "Fixed RAM for $Target" -Minimum 512MB -Maximum $HostMemoryCapacity
        return [pscustomobject]@{
            DynamicMemoryEnabled = $false
            MinimumBytes = $memory
            StartupBytes = $memory
            MaximumBytes = $memory
        }
    }

    $minimum = 512MB
    $maximum = Read-LabSize -Prompt "Maximum Dynamic Memory for $Target" -Minimum $minimum -Maximum $HostMemoryCapacity
    $startup = Read-LabSize -Prompt "Startup RAM for $Target" -Minimum $minimum -Maximum $maximum
    return [pscustomobject]@{
        DynamicMemoryEnabled = $true
        MinimumBytes = $minimum
        StartupBytes = $startup
        MaximumBytes = $maximum
    }
}

function Read-LabParentDisk {
    while ($true) {
        $path = Read-Host 'Parent OS VHDX path [example D:\Differencing\Template2025.vhdx]'
        if ([string]::IsNullOrWhiteSpace($path)) {
            $path = 'D:\Differencing\Template2025.vhdx'
        }
        $path = $path.Trim().Trim('"')
        try {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
                [IO.Path]::GetExtension($path) -ine '.vhdx') {
                throw 'Select an existing VHDX file.'
            }
            $resolved = Resolve-Path -LiteralPath $path -ErrorAction Stop
            if ($resolved.Provider.Name -ne 'FileSystem') {
                throw 'The parent must be a filesystem VHDX.'
            }
            $vhd = Get-VHD -Path $resolved.ProviderPath -ErrorAction Stop
            $directVMDisks = @(
                foreach ($vm in @(Get-VM -ErrorAction Stop)) {
                    Get-VMHardDiskDrive -VM $vm -ErrorAction Stop |
                        Where-Object { $_.Path -ieq $resolved.ProviderPath }
                }
            )
            if ($directVMDisks.Count -gt 0) {
                throw 'The parent is directly attached to a VM. Detach the template itself before using it as a parent; existing differencing children may remain attached.'
            }
            # Attached can also be true for an ancestor of an active differencing disk.
            if ($vhd.Attached) {
                $mountedParents = @(
                    Get-Disk -ErrorAction Stop |
                        Where-Object { $_.BusType -eq 'File Backed Virtual' } |
                        ForEach-Object { Get-VHD -DiskNumber $_.Number -ErrorAction Stop } |
                        Where-Object { $_.Path -ieq $resolved.ProviderPath }
                )
                if ($mountedParents.Count -gt 0) {
                    throw 'The parent is directly mounted on the host. Dismount the template itself before using it as a parent.'
                }
            }
            if (-not (Test-VHD -Path $resolved.ProviderPath -ErrorAction Stop)) {
                throw 'The parent VHDX or its backing chain is not usable.'
            }
            return $resolved.ProviderPath
        }
        catch {
            Write-Warning "Cannot use parent '$path': $($_.Exception.Message)"
        }
    }
}

function Assert-LabNamePrefix {
    param([string]$Prefix)

    if ($Prefix -notmatch '^[A-Za-z][A-Za-z0-9-]{0,12}$') {
        throw 'Use a VM prefix of 1-13 letters, digits or hyphens, beginning with a letter. Two digits are reserved for numbering within the 15-character Windows computer-name limit.'
    }
}

function Read-LabNamePrefix {
    while ($true) {
        $prefix = Read-Host 'VM naming prefix (for example MSLABVM -> MSLABVM01) [HypNode]'
        if ([string]::IsNullOrWhiteSpace($prefix)) {
            $prefix = 'HypNode'
        }
        try {
            $prefix = $prefix.Trim()
            Assert-LabNamePrefix -Prefix $prefix
            return $prefix
        }
        catch {
            Write-Warning $_.Exception.Message
        }
    }
}

function Get-LabVMNames {
    param([int]$Count, [string]$Root, [string]$Prefix, [string[]]$ExistingNames)

    Assert-LabNamePrefix -Prefix $Prefix
    $used = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $ExistingNames) {
        [void]$used.Add($name)
    }
    $suffix = 1
    $found = 0
    while ($found -lt $Count) {
        $name = '{0}{1:D2}' -f $Prefix, $suffix
        $legacyName = "$Prefix$suffix"
        $suffix++
        if ($name.Length -gt 15) {
            throw "VM name '$name' exceeds the 15-character Windows computer-name limit. Use a shorter prefix."
        }
        if ($used.Contains($name) -or $used.Contains($legacyName) -or
            (Test-Path -LiteralPath (Join-Path $Root $name)) -or
            (Test-Path -LiteralPath (Join-Path $Root $legacyName))) {
            continue
        }
        [void]$used.Add($name)
        $found++
        $name
    }
}

function Read-LabSwitchName {
    param([string]$Group, [string]$PreferredName, [object[]]$Switches)

    if ($Switches.Count -eq 0) {
        throw "No virtual switches exist. Create the required $Group switch before running this script."
    }
    Write-Host "`nSelect the existing switch for all $Group adapters:"
    $default = 0
    for ($index = 0; $index -lt $Switches.Count; $index++) {
        Write-Host "$($index + 1): $($Switches[$index].Name) ($($Switches[$index].SwitchType))"
        if ($Switches[$index].Name -ieq $PreferredName) {
            $default = $index + 1
        }
    }
    if ($default -eq 0) {
        Write-Warning "Switch '$PreferredName' was not found. Select the intended existing switch."
    }
    $selection = Read-LabInteger -Prompt "$Group switch number" -Minimum 1 -Maximum $Switches.Count -Default $default
    return $Switches[$selection - 1].Name
}

function Read-LabDataDiskSizes {
    param([string]$Target)

    $count = Read-LabInteger -Prompt "Additional dynamic data disks for $Target" -Minimum 0 -Maximum 63 -Default 2
    if ($count -eq 0) {
        return
    }

    Write-Host "`nData disk sizing: 1 = same capacity for all dynamic data disks, 2 = configure each data disk capacity"
    $sizeMode = Read-LabInteger -Prompt "Data disk capacity assignment for $Target" -Minimum 1 -Maximum 2 -Default 1
    if ($sizeMode -eq 1) {
        $size = Read-LabSize -Prompt "Capacity for all $count data disks for $Target" -Minimum 1GB -Maximum 64TB
        for ($disk = 1; $disk -le $count; $disk++) {
            $size
        }
    }
    else {
        for ($disk = 1; $disk -le $count; $disk++) {
            Read-LabSize -Prompt "Data disk $disk capacity for $Target" -Minimum 1GB -Maximum 64TB
        }
    }
}

function Read-LabVMPlans {
    param([string[]]$Names, [object]$HostInfo, [object[]]$Switches)

    Write-Host "`nCompute: 1 = same RAM/CPU for all VMs, 2 = configure each VM"
    $computeMode = Read-LabInteger -Prompt 'Compute assignment' -Minimum 1 -Maximum 2 -Default 1
    if ($computeMode -eq 1) {
        $sharedMemory = Read-LabMemorySettings -Target 'every VM' -HostMemoryCapacity $HostInfo.MemoryCapacity
        $sharedCPU = Read-LabInteger -Prompt 'vCPUs per VM' -Minimum 1 -Maximum $HostInfo.LogicalProcessorCount -Default ([Math]::Min(4, $HostInfo.LogicalProcessorCount))
    }
    $plans = @(
        foreach ($name in $Names) {
            if ($computeMode -eq 2) {
                $memory = Read-LabMemorySettings -Target $name -HostMemoryCapacity $HostInfo.MemoryCapacity
                $cpu = Read-LabInteger -Prompt "vCPUs for $name" -Minimum 1 -Maximum $HostInfo.LogicalProcessorCount -Default ([Math]::Min(4, $HostInfo.LogicalProcessorCount))
            }
            else {
                $memory = $sharedMemory
                $cpu = $sharedCPU
            }
            [pscustomobject]@{
                Name = $name
                MemoryBytes = $memory.StartupBytes
                DynamicMemoryEnabled = $memory.DynamicMemoryEnabled
                MemoryMinimumBytes = $memory.MinimumBytes
                MemoryMaximumBytes = $memory.MaximumBytes
                CPUCount = $cpu
                DataDiskSizes = @()
                NetworkAdapters = @()
            }
        }
    )

    Write-Host "`nExtra data disks: 0 = none, 1 = same disks for all VMs, 2 = configure each VM"
    $diskMode = Read-LabInteger -Prompt 'Data disk assignment' -Minimum 0 -Maximum 2 -Default 0
    if ($diskMode -eq 1) {
        $sharedDisks = @(Read-LabDataDiskSizes -Target 'every VM')
        foreach ($plan in $plans) {
            $plan.DataDiskSizes = $sharedDisks
        }
    }
    elseif ($diskMode -eq 2) {
        foreach ($plan in $plans) {
            $plan.DataDiskSizes = @(Read-LabDataDiskSizes -Target $plan.Name)
        }
    }

    $natCount = Read-LabInteger -Prompt 'NAT adapters per VM' -Minimum 0 -Maximum 8 -Default 2
    $smbCount = Read-LabInteger -Prompt 'SMB adapters per VM' -Minimum 0 -Maximum (8 - $natCount) -Default ([Math]::Min(2, 8 - $natCount))
    $adapters = @(
        if ($natCount -gt 0) {
            $natSwitch = Read-LabSwitchName -Group 'NAT' -PreferredName 'Natswitch' -Switches $Switches
            for ($nic = 1; $nic -le $natCount; $nic++) {
                [pscustomobject]@{ Name = "NAT$nic"; SwitchName = $natSwitch }
            }
        }
        if ($smbCount -gt 0) {
            $smbSwitch = Read-LabSwitchName -Group 'SMB' -PreferredName 'SMB-Network' -Switches $Switches
            for ($nic = 1; $nic -le $smbCount; $nic++) {
                [pscustomobject]@{ Name = "SMB$nic"; SwitchName = $smbSwitch }
            }
        }
    )
    foreach ($plan in $plans) {
        $plan.NetworkAdapters = $adapters
    }
    return $plans
}

function New-LabVirtualMachine {
    param([object]$Plan, [string]$Root, [string]$ParentPath, [bool]$MacSpoofing)

    $folder = Join-Path $Root $Plan.Name
    $existing = @(Get-VM -ErrorAction Stop | Where-Object { $_.Name -ieq $Plan.Name })
    if ($existing.Count -gt 0 -or (Test-Path -LiteralPath $folder)) {
        throw "VM name or folder '$($Plan.Name)' is now in use. No existing resources were changed."
    }

    [void](New-Item -Path $folder -ItemType Directory -ErrorAction Stop)
    $diskFolder = Join-Path $folder 'Virtual Hard Disks'
    [void](New-Item -Path $diskFolder -ItemType Directory -ErrorAction Stop)
    $osPath = Join-Path $diskFolder "$($Plan.Name)-OS.vhdx"
    [void](New-VHD -Path $osPath -ParentPath $ParentPath -Differencing -ErrorAction Stop)
    $vm = New-VM -Name $Plan.Name -Generation 2 -MemoryStartupBytes $Plan.MemoryBytes -NoVHD -Path $folder -ErrorAction Stop
    if ($Plan.DynamicMemoryEnabled) {
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $true -MinimumBytes $Plan.MemoryMinimumBytes `
            -StartupBytes $Plan.MemoryBytes -MaximumBytes $Plan.MemoryMaximumBytes -ErrorAction Stop
    }
    else {
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -ErrorAction Stop
    }
    Set-VMProcessor -VM $vm -Count $Plan.CPUCount -ExposeVirtualizationExtensions $true -ErrorAction Stop

    Add-VMHardDiskDrive -VM $vm -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0 -Path $osPath -ErrorAction Stop
    $osDisk = Get-VMHardDiskDrive -VM $vm -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0 -ErrorAction Stop
    Set-VMFirmware -VM $vm -FirstBootDevice $osDisk -ErrorAction Stop
    for ($index = 0; $index -lt $Plan.DataDiskSizes.Count; $index++) {
        $dataPath = Join-Path $diskFolder ('{0}-Data{1:D2}.vhdx' -f $Plan.Name, ($index + 1))
        [void](New-VHD -Path $dataPath -Dynamic -SizeBytes $Plan.DataDiskSizes[$index] -ErrorAction Stop)
        Add-VMHardDiskDrive -VM $vm -ControllerType SCSI -ControllerNumber 0 -ControllerLocation ($index + 1) -Path $dataPath -ErrorAction Stop
    }

    # Integration-service names are localized; identify time synchronization by its service GUID.
    $timeSync = @(Get-VMIntegrationService -VM $vm -ErrorAction Stop | Where-Object {
        $_.Id -match '2497f4de-e9fa-4204-80e4-4b75c46419c0'
    })
    if ($timeSync.Count -ne 1) {
        throw "Could not uniquely identify the time synchronization service for '$($Plan.Name)'."
    }
    Disable-VMIntegrationService -VM $vm -Name $timeSync[0].Name -ErrorAction Stop

    Remove-VMNetworkAdapter -VM $vm -Confirm:$false -ErrorAction Stop
    foreach ($adapter in $Plan.NetworkAdapters) {
        Add-VMNetworkAdapter -VM $vm -Name $adapter.Name -SwitchName $adapter.SwitchName -ErrorAction Stop
    }
    if ($Plan.NetworkAdapters.Count -gt 0) {
        if ($MacSpoofing) {
            Set-VMNetworkAdapter -VM $vm -MacAddressSpoofing On -AllowTeaming On `
                -DeviceNaming On -ErrorAction Stop
        }
        else {
            Set-VMNetworkAdapter -VM $vm -AllowTeaming On -DeviceNaming On -ErrorAction Stop
        }
    }
    return $vm
}

function Get-LabHostInfo {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script in an elevated PowerShell window on the Hyper-V host.'
    }
    Import-Module Hyper-V -ErrorAction Stop
    return Get-VMHost -ErrorAction Stop
}

function Invoke-HyperVLabProvisioning {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$VMRoot, [string]$NamePrefix, [Nullable[bool]]$StartVMs)

    $ErrorActionPreference = 'Stop'
    if ([string]::IsNullOrWhiteSpace($NamePrefix)) {
        $NamePrefix = Read-LabNamePrefix
    }
    Assert-LabNamePrefix -Prefix $NamePrefix
    $hostInfo = Get-LabHostInfo
    $VMRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($VMRoot)
    if ((Test-Path -LiteralPath $VMRoot) -and -not (Test-Path -LiteralPath $VMRoot -PathType Container)) {
        throw "VM root '$VMRoot' is not a directory."
    }
    $driveRoot = [IO.Path]::GetPathRoot($VMRoot)
    if (-not (Test-Path -LiteralPath $driveRoot -PathType Container)) {
        throw "Storage root '$driveRoot' is not accessible."
    }

    $count = Read-LabInteger -Prompt 'How many VMs would you like to create?' -Minimum 1 -Default 4
    $parentPath = Read-LabParentDisk
    $names = @(Get-LabVMNames -Count $count -Root $VMRoot -Prefix $NamePrefix -ExistingNames @(
        Get-VM -ErrorAction Stop | Select-Object -ExpandProperty Name
    ))
    $plans = @(Read-LabVMPlans -Names $names -HostInfo $hostInfo -Switches @(
        Get-VMSwitch -ErrorAction Stop | Sort-Object Name
    ))
    $macSpoofing = Read-LabYesNo -Prompt 'Enable MAC address spoofing for bridged nested-VM networking?' -Default $true
    $shouldStartVMs = if ($null -eq $StartVMs) {
        Read-LabYesNo -Prompt 'Start the new VMs after all have been configured?' -Default $false
    }
    else {
        [bool]$StartVMs
    }

    Write-Host "`nParent OS disk: $parentPath"
    Write-Host "VM root: $VMRoot"
    Write-Host 'Generation 2; selected fixed/dynamic RAM; nested virtualization ON; host time synchronization OFF.'
    Write-Host "MAC address spoofing: $macSpoofing; start after creation: $shouldStartVMs"
    $plans | Select-Object Name, @{Name = 'Memory'; Expression = { if ($_.DynamicMemoryEnabled) { 'Dynamic' } else { 'Fixed' } }},
        @{Name = 'Minimum_GB'; Expression = { $_.MemoryMinimumBytes / 1GB }},
        @{Name = 'Startup_GB'; Expression = { $_.MemoryBytes / 1GB }},
        @{Name = 'Maximum_GB'; Expression = { $_.MemoryMaximumBytes / 1GB }}, CPUCount,
        @{Name = 'DataDisks_GB'; Expression = { ($_.DataDiskSizes | ForEach-Object { $_ / 1GB }) -join ', ' }},
        @{Name = 'NICs'; Expression = { ($_.NetworkAdapters | ForEach-Object { "$($_.Name) -> $($_.SwitchName)" }) -join '; ' }} |
        Format-Table -AutoSize -Wrap | Out-Host
    $totalStartupMemory = ($plans | Measure-Object -Property MemoryBytes -Sum).Sum
    if ($totalStartupMemory -ge $hostInfo.MemoryCapacity) {
        Write-Warning 'Planned startup RAM meets or exceeds physical host RAM. Allow for the host, MylabAD01, and other running VMs.'
    }
    $totalMaximumMemory = ($plans | Measure-Object -Property MemoryMaximumBytes -Sum).Sum
    if ($totalMaximumMemory -gt $totalStartupMemory -and $totalMaximumMemory -ge $hostInfo.MemoryCapacity) {
        Write-Warning 'Combined Dynamic Memory ceilings meet or exceed physical host RAM. Hyper-V may not satisfy every VM at its maximum simultaneously.'
    }
    Write-Warning 'Use a generalized Generation 2 Windows template. Do not modify, move, or delete the parent while children exist.'
    if (-not $PSCmdlet.ShouldProcess($VMRoot, "Create $count new lab VMs: $($names -join ', ')")) {
        return
    }
    if (-not (Read-LabYesNo -Prompt 'Create these VMs now?' -Default $false)) {
        Write-Host 'Cancelled. No VMs or disks were created.'
        return
    }

    $created = @()
    $currentName = ''
    try {
        if (-not (Test-Path -LiteralPath $VMRoot)) {
            [void](New-Item -Path $VMRoot -ItemType Directory -ErrorAction Stop)
        }
        foreach ($plan in $plans) {
            $currentName = $plan.Name
            $created += New-LabVirtualMachine -Plan $plan -Root $VMRoot -ParentPath $parentPath -MacSpoofing $macSpoofing
            Write-Host "Configured $currentName."
        }
        if ($shouldStartVMs) {
            foreach ($vm in $created) {
                $currentName = $vm.Name
                Start-VM -VM $vm -ErrorAction Stop
            }
        }
    }
    catch {
        throw "Provisioning stopped at '$currentName': $($_.Exception.Message) Resources created so far were preserved for inspection; no existing VMs were changed. Check '$VMRoot' and Hyper-V Manager before retrying."
    }
    Write-Host "`nSuccessfully configured $($created.Count) VMs."
    return $created
}


function Read-LabCredential {
    param([AllowEmptyString()][string]$UserName, [string]$Message)

    $credential = if ([string]::IsNullOrWhiteSpace($UserName)) {
        Get-Credential -Message $Message
    }
    else {
        Get-Credential -UserName $UserName -Message $Message
    }
    if ($null -eq $credential) {
        throw 'Credential entry was cancelled.'
    }
    return $credential
}

function Assert-LabNetworkSettings {
    param([string]$SubnetPrefix, [string]$Gateway, [string]$DnsServer, [int]$PrefixLength)

    if ($PrefixLength -ne 24) {
        throw 'This configured variant currently supports only a /24 subnet.'
    }
    foreach ($address in @($Gateway, $DnsServer)) {
        $parsed = $null
        if (-not [Net.IPAddress]::TryParse($address, [ref]$parsed) -or
            $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
            throw "'$address' is not a valid IPv4 address."
        }
        if ($address -notlike "$SubnetPrefix.*") {
            throw "'$address' is outside $SubnetPrefix.0/$PrefixLength."
        }
    }
    if ($Gateway -eq $DnsServer) {
        throw 'The gateway and DNS server addresses must be different.'
    }
}

function Wait-LabPowerShellDirect {
    param(
        [string]$VMName,
        [PSCredential]$Credential,
        [int]$TimeoutSeconds = 900,
        [Nullable[datetime]]$PreviousBootTime,
        [switch]$FailOnInvalidCredential
    )

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastError = $null
    $nextStatusSeconds = 0
    if ($null -ne $PreviousBootTime) {
        Write-Host "Waiting for a new Windows boot and PowerShell Direct in '$VMName'."
    }
    else {
        Write-Host "Waiting for PowerShell Direct in '$VMName'. The guest must finish first-boot setup and accept the supplied guest credential."
    }
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            [void](Invoke-Command -VMName $VMName -Credential $Credential -ArgumentList $PreviousBootTime -ScriptBlock {
                param($PreviousBootTime)
                if ($null -ne $PreviousBootTime) {
                    $bootTime = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
                    if ($null -eq $bootTime -or $bootTime -le $PreviousBootTime) {
                        throw 'The scheduled guest restart has not completed yet.'
                    }
                }
                $env:COMPUTERNAME
            } -ErrorAction Stop)
            Write-Host "PowerShell Direct is ready in '$VMName'."
            return
        }
        catch {
            $lastError = $_.Exception.Message
            $authenticationFailed = $_.FullyQualifiedErrorId -match '^InvalidCredential(?:,|$)' -or
                $lastError -match '(?i)\bthe credential is invalid\b'
            $exception = $_.Exception
            while ($null -ne $exception -and -not $authenticationFailed) {
                # Windows PowerShell uses PSRemotingErrorId.InvalidCredential (964).
                if ($exception -is [System.Management.Automation.Remoting.PSRemotingTransportException] -and
                    $exception.ErrorCode -eq 964) {
                    $authenticationFailed = $true
                }
                $exception = $exception.InnerException
            }
            if ($FailOnInvalidCredential -and $null -eq $PreviousBootTime -and $authenticationFailed) {
                throw "PowerShell Direct authentication failed for '$VMName' using '$($Credential.UserName)'. Sign in locally to the guest, run hostname and whoami, then supply its current Windows hostname and local account (for example, CURRENT-WINDOWS-NAME\Administrator) with the working local password. The Windows hostname may differ from the Hyper-V VM name after a partial domain join. This is not evidence that the guest is blocked at OOBE. Authentication retries were stopped. Original error: $lastError"
            }
            if ($timer.Elapsed.TotalSeconds -ge $nextStatusSeconds) {
                $elapsed = [Math]::Floor($timer.Elapsed.TotalSeconds)
                if ($null -ne $PreviousBootTime) {
                    Write-Host "Still waiting for '$VMName' to restart ($elapsed seconds). Last error: $lastError"
                }
                else {
                    Write-Host "Still waiting for '$VMName' ($elapsed seconds). Last error: $lastError"
                }
                $nextStatusSeconds += 30
            }
            Start-Sleep -Seconds 5
        }
    }
    if ($null -ne $PreviousBootTime) {
        throw "Guest '$VMName' did not complete its restart and become ready for PowerShell Direct within $TimeoutSeconds seconds. Last error: $lastError"
    }
    throw "PowerShell Direct did not become ready for '$VMName' within $TimeoutSeconds seconds. Check the guest console, vmicvmsession service, and supplied guest credential. Only if the console shows OOBE, complete setup manually or rebuild the parent with Prepare-HyperVLabTemplate.ps1. Last error: $lastError"
}

function Restart-LabGuest {
    param(
        [string]$VMName,
        [PSCredential]$Credential,
        [PSCredential]$RestartCredential,
        [int]$TimeoutSeconds = 900
    )

    $previousBootTime = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        $bootTime = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        if ($null -eq $bootTime) {
            throw 'Cannot verify a guest restart without the current Windows boot time.'
        }
        $restart = Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" `
            -ArgumentList '/r /t 5 /f /d p:2:4 /c "Completing automated lab configuration"' `
            -PassThru -Wait -ErrorAction Stop
        if ($restart.ExitCode -ne 0) {
            throw "Windows shutdown scheduling failed with exit code $($restart.ExitCode)."
        }
        $bootTime
    } -ErrorAction Stop
    Wait-LabPowerShellDirect -VMName $VMName -Credential $RestartCredential `
        -TimeoutSeconds $TimeoutSeconds -PreviousBootTime $previousBootTime
}

$script:LabGuestHypervisorBootConfiguration = {
    param([bool]$Configure = $false)

    $ErrorActionPreference = 'Stop'
    # BCD identifiers avoid parsing localized BCDEdit output.
    $currentLoaderId = '{fa926493-6f1c-4193-a414-58f0b2456d1e}'
    $launchTypeElement = [uint32]0x250000F0
    $store = Invoke-CimMethod -Namespace 'root\WMI' -ClassName BcdStore `
        -MethodName OpenStore -Arguments @{ File = '' } -ErrorAction Stop
    if ($store.ReturnValue -ne $true -or $null -eq $store.Store) {
        throw 'Could not open the guest system BCD store. Verify guest administrator access.'
    }
    $loader = Invoke-CimMethod -InputObject $store.Store -MethodName OpenObject `
        -Arguments @{ Id = $currentLoaderId } -ErrorAction Stop
    if ($loader.ReturnValue -ne $true -or $null -eq $loader.Object) {
        throw 'Could not open the current guest Windows boot loader.'
    }

    function Get-LabHypervisorLaunchType {
        $result = Invoke-CimMethod -InputObject $loader.Object -MethodName EnumerateElements -ErrorAction Stop
        if ($result.ReturnValue -ne $true -or $null -eq $result.Elements) {
            throw 'Could not enumerate the current guest Windows boot settings.'
        }
        $elements = @($result.Elements | Where-Object Type -EQ $launchTypeElement)
        if ($elements.Count -eq 0) { return 'NotConfigured' }
        if ($elements.Count -ne 1 -or $null -eq $elements[0].Integer -or
            $elements[0].Integer -notin @(0, 1)) {
            throw 'The guest hypervisorlaunchtype BCD element has an unexpected value.'
        }
        if ($elements[0].Integer -eq 1) { return 'Auto' }
        return 'Off'
    }

    $launchType = Get-LabHypervisorLaunchType
    $changed = $Configure -and $launchType -ne 'Auto'
    if ($changed) {
        $updated = Invoke-CimMethod -InputObject $loader.Object -MethodName SetIntegerElement `
            -Arguments @{ Type = $launchTypeElement; Integer = [uint64]1 } -ErrorAction Stop
        if ($updated.ReturnValue -ne $true) {
            throw 'Could not set guest hypervisorlaunchtype to Auto in the current Windows boot entry.'
        }
        $launchType = Get-LabHypervisorLaunchType
    }
    if ($launchType -ne 'Auto') {
        throw "Guest hypervisorlaunchtype is '$launchType', not Auto."
    }
    [pscustomobject]@{ HypervisorLaunchType = $launchType; Changed = $changed }
}

function Enable-LabGuestHypervisor {
    param(
        [string]$VMName,
        [PSCredential]$Credential,
        [int]$TimeoutSeconds = 900
    )

    $processors = @(Get-VMProcessor -VMName $VMName -ErrorAction Stop)
    if ($processors.Count -ne 1 -or $processors[0].ExposeVirtualizationExtensions -ne $true) {
        throw "Virtualization extensions are not verified as exposed for '$VMName'. Shut down the VM, run Set-VMProcessor -VMName '$VMName' -ExposeVirtualizationExtensions `$true on the Hyper-V host, then start the VM and resume configuration."
    }
    $state = Invoke-Command -VMName $VMName -Credential $Credential -ArgumentList $true `
        -ScriptBlock $script:LabGuestHypervisorBootConfiguration -ErrorAction Stop
    if ($state.HypervisorLaunchType -ne 'Auto' -or $null -eq $state.Changed) {
        throw "Could not verify guest hypervisor startup configuration in '$VMName'."
    }
    if ($state.Changed) {
        Write-Host "Set guest hypervisorlaunchtype to Auto in '$VMName'; restarting the guest before continuing."
        Restart-LabGuest -VMName $VMName -Credential $Credential `
            -RestartCredential $Credential -TimeoutSeconds $TimeoutSeconds
        $verified = Invoke-Command -VMName $VMName -Credential $Credential -ArgumentList $false `
            -ScriptBlock $script:LabGuestHypervisorBootConfiguration -ErrorAction Stop
        if ($verified.HypervisorLaunchType -ne 'Auto') {
            throw "Guest hypervisorlaunchtype did not remain Auto after restarting '$VMName'."
        }
    }
    Write-Host "Nested virtualization settings verified in '$VMName': host CPU exposure enabled and guest hypervisorlaunchtype Auto."
}

function Disable-LabGuestFirewall {
    param(
        [string]$VMName,
        [PSCredential]$Credential,
        [ValidateRange(0, 600)]
        [int]$StabilizationSeconds = 0,
        [ValidateRange(1, 60)]
        [int]$RetryIntervalSeconds = 15
    )

    $attemptCount = if ($StabilizationSeconds -eq 0) {
        1
    }
    else {
        [int][Math]::Ceiling($StabilizationSeconds / $RetryIntervalSeconds) + 1
    }
    for ($attempt = 1; $attempt -le $attemptCount; $attempt++) {
        try {
            $profiles = @(Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
                Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled False -ErrorAction Stop
                $state = @(Get-NetFirewallProfile -Profile Domain, Private, Public -ErrorAction Stop |
                    Select-Object Name, Enabled)
                $enabled = @($state | Where-Object { $_.Enabled })
                if ($enabled.Count -gt 0) {
                    throw "Windows Firewall remains enabled for: $($enabled.Name -join ', ')."
                }
                $state
            } -ErrorAction Stop)

            $enabledProfiles = @($profiles | Where-Object { $_.Enabled })
            if ($profiles.Count -ne 3 -or $enabledProfiles.Count -gt 0) {
                throw "Could not verify all Windows Firewall profiles as disabled in '$VMName'."
            }
        }
        catch {
            if ($attempt -eq $attemptCount) {
                throw "Could not keep all Windows Firewall profiles disabled in '$VMName' after $attempt attempts: $($_.Exception.Message)"
            }
            Write-Warning "Firewall enforcement attempt $attempt failed for '$VMName': $($_.Exception.Message) Retrying."
        }
        if ($attempt -lt $attemptCount) {
            Start-Sleep -Seconds $RetryIntervalSeconds
        }
    }
    Write-Host "Windows Firewall is disabled for Domain, Private, and Public profiles in '$VMName' after $attemptCount verification attempt(s)."
}

function Set-LabGuestTimeZone {
    param(
        [string]$VMName,
        [PSCredential]$Credential,
        [string]$TimeZoneId = 'India Standard Time'
    )

    $timeZone = Invoke-Command -VMName $VMName -Credential $Credential `
        -ArgumentList $TimeZoneId -ScriptBlock {
        param($ExpectedTimeZoneId)
        Set-TimeZone -Id $ExpectedTimeZoneId -ErrorAction Stop
        Get-TimeZone -ErrorAction Stop | Select-Object Id, DisplayName
    } -ErrorAction Stop
    if ($timeZone.Id -ine $TimeZoneId) {
        throw "Could not verify time zone '$TimeZoneId' in '$VMName'; guest reports '$($timeZone.Id)'."
    }
    Write-Host "Time zone '$TimeZoneId' is configured in '$VMName'."
}

function Test-LabDomainController {
    param(
        [string]$VMName,
        [string]$DomainName,
        [string]$DnsServer,
        [PSCredential]$Credential
    )

    $domainController = @(Get-VM -Name $VMName -ErrorAction Stop)
    if ($domainController.Count -ne 1) {
        throw "Expected exactly one domain controller VM named '$VMName'."
    }
    if ([string]$domainController[0].State -ine 'Running') {
        throw "Domain controller VM '$VMName' must be running."
    }

    $result = Invoke-Command -VMName $VMName -Credential $Credential -ArgumentList $DomainName, $DnsServer -ScriptBlock {
        param($ExpectedDomainName, $ExpectedDnsServer)

        Import-Module ActiveDirectory -ErrorAction Stop
        $domain = Get-ADDomain -Identity $ExpectedDomainName -ErrorAction Stop
        $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Select-Object -ExpandProperty IPAddress)
        [void](Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$ExpectedDomainName" -Type SRV `
            -Server $ExpectedDnsServer -DnsOnly -ErrorAction Stop)
        [pscustomobject]@{
            DnsRoot = $domain.DNSRoot
            DistinguishedName = $domain.DistinguishedName
            IPv4Addresses = $addresses
        }
    } -ErrorAction Stop

    if ($result.DnsRoot -ine $DomainName) {
        throw "VM '$VMName' hosts domain '$($result.DnsRoot)', not '$DomainName'."
    }
    if (@($result.IPv4Addresses) -inotcontains $DnsServer) {
        throw "Domain controller VM '$VMName' does not report required DNS address '$DnsServer'."
    }
    return $result
}

function Get-LabOUBaseName {
    param([string]$NamePrefix)

    Assert-LabNamePrefix -Prefix $NamePrefix
    if ($NamePrefix -imatch 'VM$') {
        return $NamePrefix -replace '(?i)VM$', 'OU'
    }
    return "${NamePrefix}OU"
}

function Get-LabNextSerializedName {
    param([string]$BaseName, [string[]]$ExistingNames)

    $used = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($ExistingNames)) {
        [void]$used.Add($name)
    }
    $suffix = 0
    do {
        $candidate = if ($suffix -eq 0) { $BaseName } else { '{0}{1:D2}' -f $BaseName, $suffix }
        $legacyName = if ($suffix -eq 0) { $BaseName } else { "$BaseName$suffix" }
        $suffix++
    } while ($used.Contains($candidate) -or $used.Contains($legacyName))
    return $candidate
}

function New-LabSerializedOU {
    param(
        [string]$DomainControllerVMName,
        [string]$DomainName,
        [string]$BaseName,
        [PSCredential]$Credential
    )

    $domainData = Invoke-Command -VMName $DomainControllerVMName -Credential $Credential `
        -ArgumentList $DomainName -ScriptBlock {
        param($ExpectedDomainName)

        Import-Module ActiveDirectory -ErrorAction Stop
        $domain = Get-ADDomain -Identity $ExpectedDomainName -ErrorAction Stop
        $names = @(Get-ADOrganizationalUnit -SearchBase $domain.DistinguishedName `
            -SearchScope OneLevel -Filter * -ErrorAction Stop | Select-Object -ExpandProperty Name)
        [pscustomobject]@{
            DistinguishedName = $domain.DistinguishedName
            ExistingNames = $names
        }
    } -ErrorAction Stop

    $name = Get-LabNextSerializedName -BaseName $BaseName -ExistingNames @($domainData.ExistingNames)
    $ou = Invoke-Command -VMName $DomainControllerVMName -Credential $Credential `
        -ArgumentList $name, $domainData.DistinguishedName -ScriptBlock {
        param($OUName, $DomainDistinguishedName)

        Import-Module ActiveDirectory -ErrorAction Stop
        $existing = @(Get-ADOrganizationalUnit -SearchBase $DomainDistinguishedName `
            -SearchScope OneLevel -LDAPFilter "(ou=$OUName)" -ErrorAction Stop)
        if ($existing.Count -gt 0) {
            throw "OU '$OUName' appeared during allocation. Run the configured variant again."
        }
        New-ADOrganizationalUnit -Name $OUName -Path $DomainDistinguishedName `
            -ProtectedFromAccidentalDeletion $true -PassThru -ErrorAction Stop |
            Select-Object Name, DistinguishedName
    } -ErrorAction Stop
    return $ou
}

function Get-LabExistingOU {
    param(
        [string]$DomainControllerVMName,
        [string]$DomainName,
        [string]$Name,
        [PSCredential]$Credential
    )

    $ou = @(Invoke-Command -VMName $DomainControllerVMName -Credential $Credential `
        -ArgumentList $DomainName, $Name -ScriptBlock {
        param($ExpectedDomainName, $OUName)

        Import-Module ActiveDirectory -ErrorAction Stop
        $domain = Get-ADDomain -Identity $ExpectedDomainName -ErrorAction Stop
        Get-ADOrganizationalUnit -SearchBase $domain.DistinguishedName `
            -SearchScope OneLevel -LDAPFilter "(ou=$OUName)" -ErrorAction Stop |
            Select-Object Name, DistinguishedName
    } -ErrorAction Stop)
    if ($ou.Count -ne 1) {
        throw "Expected exactly one root-level OU named '$Name' in '$DomainName'."
    }
    return $ou[0]
}

function Get-LabReportedIPv4Addresses {
    $addresses = foreach ($vm in @(Get-VM -ErrorAction Stop)) {
        foreach ($adapter in @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop)) {
            foreach ($address in @($adapter.IPAddresses)) {
                $parsed = $null
                if ([Net.IPAddress]::TryParse([string]$address, [ref]$parsed) -and
                    $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) {
                    $parsed.IPAddressToString
                }
            }
        }
    }
    return @($addresses | Sort-Object -Unique)
}

function Get-LabIPv4Candidates {
    param(
        [string]$SubnetPrefix,
        [string]$Gateway,
        [string]$DnsServer,
        [string[]]$OccupiedAddresses
    )

    $occupied = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($address in @($OccupiedAddresses) + @($Gateway, $DnsServer)) {
        [void]$occupied.Add([string]$address)
    }
    for ($hostNumber = 2; $hostNumber -le 254; $hostNumber++) {
        $candidate = "$SubnetPrefix.$hostNumber"
        if (-not $occupied.Contains($candidate)) {
            $candidate
        }
    }
}

function Get-LabAvailableIPv4Addresses {
    param(
        [int]$RequiredCount,
        [string]$SubnetPrefix,
        [string]$Gateway,
        [string]$DnsServer,
        [string]$DomainName,
        [string]$DomainControllerVMName,
        [PSCredential]$DomainCredential
    )

    $reported = @(Get-LabReportedIPv4Addresses)
    $candidates = @(Get-LabIPv4Candidates -SubnetPrefix $SubnetPrefix -Gateway $Gateway `
        -DnsServer $DnsServer -OccupiedAddresses $reported)
    $request = [pscustomobject]@{
        Candidates = [string[]]$candidates
        DnsZoneName = $DomainName
        Count = $RequiredCount
    }
    $available = @(Invoke-Command -VMName $DomainControllerVMName -Credential $DomainCredential `
        -ArgumentList $request -ScriptBlock {
        param($Request)

        Import-Module DnsServer -ErrorAction Stop
        $dnsAddresses = @(Get-DnsServerResourceRecord -ZoneName $Request.DnsZoneName -RRType A `
            -ErrorAction Stop | ForEach-Object {
            $_.RecordData.IPv4Address.IPAddressToString
        })
        $dnsUsed = [Collections.Generic.HashSet[string]]::new(
            [string[]]$dnsAddresses,
            [StringComparer]::OrdinalIgnoreCase
        )
        $free = [Collections.Generic.List[string]]::new()
        $ping = [Net.NetworkInformation.Ping]::new()
        try {
            foreach ($candidate in @($Request.Candidates)) {
                $candidateAddress = [string]$candidate
                $parsedCandidate = $null
                if (-not [Net.IPAddress]::TryParse($candidateAddress, [ref]$parsedCandidate) -or
                    $parsedCandidate.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
                    throw "Invalid IPv4 candidate '$candidateAddress' was supplied to the availability probe."
                }
                if ($dnsUsed.Contains($candidateAddress)) {
                    continue
                }
                $reply = $ping.Send($candidateAddress, 350)
                $neighbors = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop |
                    Where-Object { $_.IPAddress -eq $candidateAddress })
                $activeNeighbor = @($neighbors | Where-Object {
                    [string]$_.State -notin @('Incomplete', 'Unreachable')
                }).Count -gt 0
                if ($reply.Status -eq [Net.NetworkInformation.IPStatus]::Success -or $activeNeighbor) {
                    continue
                }
                $free.Add($candidateAddress)
                if ($free.Count -eq $Request.Count) {
                    break
                }
            }
        }
        finally {
            $ping.Dispose()
        }
        $free
    } -ErrorAction Stop)

    if ($available.Count -lt $RequiredCount) {
        throw "Only $($available.Count) free addresses were found in $SubnetPrefix.0/24; $RequiredCount are required."
    }
    return $available
}

function ConvertTo-LabNormalizedMacAddress {
    param([string]$MacAddress)

    return ($MacAddress -replace '[:-]', '').ToUpperInvariant()
}

function Get-LabGuestAdapterPlan {
    param(
        [string]$VMName,
        [string]$ManagementSwitchName,
        [string]$SmbSwitchName
    )

    $hostAdapters = @(Get-VMNetworkAdapter -VMName $VMName -ErrorAction Stop)
    $managementAdapters = @($hostAdapters |
        Where-Object { $_.SwitchName -ieq $ManagementSwitchName } |
        Sort-Object Name)
    if ($managementAdapters.Count -eq 0) {
        throw "VM '$VMName' has no adapter connected to management switch '$ManagementSwitchName'."
    }
    $smbAdapters = @($hostAdapters |
        Where-Object { $_.SwitchName -ieq $SmbSwitchName } |
        Sort-Object Name)

    $plan = @()
    for ($index = 0; $index -lt $managementAdapters.Count; $index++) {
        $plan += [pscustomobject]@{
            MacAddress = ConvertTo-LabNormalizedMacAddress $managementAdapters[$index].MacAddress
            GuestName = "mgmt$($index + 1)"
            SwitchName = $managementAdapters[$index].SwitchName
        }
    }
    for ($index = 0; $index -lt $smbAdapters.Count; $index++) {
        $plan += [pscustomobject]@{
            MacAddress = ConvertTo-LabNormalizedMacAddress $smbAdapters[$index].MacAddress
            GuestName = "smb$($index + 1)"
            SwitchName = $smbAdapters[$index].SwitchName
        }
    }
    if (@($plan | Where-Object { [string]::IsNullOrWhiteSpace($_.MacAddress) }).Count -gt 0) {
        throw "VM '$VMName' has an adapter without a usable MAC address."
    }
    return $plan
}

function Invoke-LabGuestNetworkConfiguration {
    param(
        [string]$VMName,
        [PSCredential]$Credential,
        [object[]]$AdapterPlan,
        [string]$IPAddress,
        [int]$PrefixLength,
        [string]$Gateway,
        [string]$DnsServer,
        [string]$DomainName
    )

    $request = [pscustomobject]@{
        Mappings = [object[]]$AdapterPlan
        NodeAddress = $IPAddress
        PrefixLength = $PrefixLength
        DefaultGateway = $Gateway
        PrimaryDns = $DnsServer
        ExpectedDomain = $DomainName
        NetworkReadyTimeoutSeconds = 120
    }
    return Invoke-Command -VMName $VMName -Credential $Credential `
        -ArgumentList $request -ScriptBlock {
        param($Request)

        $Mappings = @($Request.Mappings)
        $NodeAddress = [string]$Request.NodeAddress
        $NodePrefixLength = [int]$Request.PrefixLength
        $DefaultGateway = [string]$Request.DefaultGateway
        $PrimaryDns = [string]$Request.PrimaryDns
        $ExpectedDomain = [string]$Request.ExpectedDomain

        function Normalize-MacAddress {
            param([string]$MacAddress)
            return ($MacAddress -replace '[:-]', '').ToUpperInvariant()
        }

        $guestAdapters = @(Get-NetAdapter -ErrorAction Stop)
        foreach ($mapping in $Mappings) {
            $matches = @($guestAdapters | Where-Object {
                (Normalize-MacAddress $_.MacAddress) -eq $mapping.MacAddress
            })
            if ($matches.Count -ne 1) {
                throw "Could not uniquely map Hyper-V MAC '$($mapping.MacAddress)' inside the guest."
            }
            $nameConflict = @($guestAdapters | Where-Object {
                $_.Name -ieq $mapping.GuestName -and $_.InterfaceGuid -ne $matches[0].InterfaceGuid
            })
            if ($nameConflict.Count -gt 0) {
                throw "Guest adapter name '$($mapping.GuestName)' is already in use."
            }
            if ($matches[0].Name -ine $mapping.GuestName) {
                Rename-NetAdapter -Name $matches[0].Name -NewName $mapping.GuestName -ErrorAction Stop
            }
        }

        $guestAdapters = @(Get-NetAdapter -ErrorAction Stop)
        $management = @($guestAdapters | Where-Object { $_.Name -ieq 'mgmt1' })
        if ($management.Count -ne 1) {
            throw "Guest '$env:COMPUTERNAME' does not have exactly one mgmt1 adapter."
        }

        foreach ($adapter in $guestAdapters) {
            $ipv6Binding = Get-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction Stop
            if ($ipv6Binding.Enabled) {
                Disable-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction Stop
            }
            Set-NetIPInterface -InterfaceIndex $adapter.IfIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop
            Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.InterfaceIndex -eq $adapter.IfIndex } |
                Remove-NetIPAddress -Confirm:$false -ErrorAction Stop
            Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object {
                    $_.InterfaceIndex -eq $adapter.IfIndex -and $_.DestinationPrefix -eq '0.0.0.0/0'
                } |
                Remove-NetRoute -Confirm:$false -ErrorAction Stop
            Set-DnsClientServerAddress -InterfaceIndex $adapter.IfIndex -ResetServerAddresses -ErrorAction Stop
        }

        [void](New-NetIPAddress -InterfaceIndex $management[0].IfIndex -IPAddress $NodeAddress `
            -PrefixLength $NodePrefixLength -DefaultGateway $DefaultGateway -ErrorAction Stop)
        Set-DnsClientServerAddress -InterfaceIndex $management[0].IfIndex `
            -ServerAddresses $PrimaryDns -ErrorAction Stop

        $configuredDns = @(Get-DnsClientServerAddress -InterfaceIndex $management[0].IfIndex `
            -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses
        if ($configuredDns -notcontains $PrimaryDns) {
            throw "DNS server '$PrimaryDns' was not applied to mgmt1."
        }

        $networkTimer = [Diagnostics.Stopwatch]::StartNew()
        $networkReady = $false
        $lastNetworkError = ''
        do {
            $configuredAddress = @(Get-NetIPAddress -InterfaceIndex $management[0].IfIndex `
                -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -eq $NodeAddress })
            if ($configuredAddress.Count -eq 1 -and
                [string]$configuredAddress[0].AddressState -ieq 'Preferred') {
                try {
                    [void](Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$ExpectedDomain" `
                        -Type SRV -Server $PrimaryDns -DnsOnly -ErrorAction Stop)
                    $networkReady = $true
                    break
                }
                catch {
                    $lastNetworkError = $_.Exception.Message
                }
            }
            elseif ($configuredAddress.Count -eq 1) {
                $lastNetworkError = "Address state is '$($configuredAddress[0].AddressState)'."
            }
            else {
                $lastNetworkError = "Static address '$NodeAddress' was not present on mgmt1."
            }
            if ($networkTimer.Elapsed.TotalSeconds -lt $Request.NetworkReadyTimeoutSeconds) {
                Start-Sleep -Seconds 5
            }
        } while ($networkTimer.Elapsed.TotalSeconds -lt $Request.NetworkReadyTimeoutSeconds)

        if (-not $networkReady) {
            $adapterState = (Get-NetAdapter -Name 'mgmt1' -ErrorAction Stop).Status
            throw "DNS server '$PrimaryDns' did not become reachable from mgmt1 within $($Request.NetworkReadyTimeoutSeconds) seconds. Adapter status: $adapterState. Last error: $lastNetworkError"
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            InterfaceAlias = $management[0].Name
            IPAddress = $NodeAddress
            Gateway = $DefaultGateway
            DnsServer = $PrimaryDns
        }
    } -ErrorAction Stop
}

# Public AVMA keys from Microsoft Learn; they require an eligible, activated Datacenter host.
$script:LabAVMAKeys = @{
    2025 = @{
        Datacenter = 'YQB4H-NKHHJ-Q6K4R-4VMY6-VCH67'
        DatacenterAzureEdition = '6NMQ9-T38WF-6MFGM-QYGYM-88J4F'
        Standard = 'WWVGQ-PNHV9-B89P4-8GGM9-9HPQ4'
    }
    2022 = @{
        Datacenter = 'W3GNR-8DDXR-2TFRP-H8P33-DV9BG'
        DatacenterAzureEdition = 'F7TB6-YKN8Y-FCC6R-KQ484-VMK3J'
        Standard = 'YDFWN-MJ9JR-3DYRK-FXXRW-78VHK'
    }
    2019 = @{
        Datacenter = 'H3RNG-8C32Q-Q8FRX-6TDXV-WMBMW'
        Standard = 'TNK62-RXVTB-4P47B-2D623-4GF74'
        Essentials = '2CTP7-NHT64-BP62M-FV6GG-HFV28'
    }
    2016 = @{
        Datacenter = 'TMJ3Y-NTRTM-FJYXT-T22BY-CWG3J'
        Standard = 'C3RCX-M6NRP-6CXC9-TW2F2-4RHYD'
        Essentials = 'B4YNW-62DX9-W8V6M-82649-MHBKQ'
    }
    2012 = @{
        Datacenter = 'Y4TGP-NPTV9-HTC2H-7MGQ3-DV4TW'
        Standard = 'DBGBW-NPF86-BJVTX-K3WKJ-MTB6V'
        Essentials = 'K2XGM-NMBT3-2R6Q8-WF2FK-P36R2'
    }
}

$script:LabAVMAWindowsDiscovery = {
    $ErrorActionPreference = 'Stop'
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -Property Caption, BuildNumber, ProductType -ErrorAction Stop
    $edition = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID -ErrorAction Stop
    $products = @(Get-CimInstance -ClassName SoftwareLicensingProduct `
        -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" `
        -Property ID, LicenseFamily, LicenseIsAddon, LicenseStatus, PartialProductKey -ErrorAction Stop |
        Where-Object { $_.LicenseIsAddon -eq $false } |
        Select-Object ID, LicenseFamily, LicenseStatus, PartialProductKey)
    [pscustomobject]@{
        Caption = $os.Caption; BuildNumber = [int]$os.BuildNumber
        ProductType = [int]$os.ProductType; EditionID = [string]$edition.EditionID; Products = $products
    }
}

function Get-LabWindowsAVMAProfile {
    param([object]$Discovery)

    if ($null -eq $Discovery -or @($Discovery).Count -ne 1 -or
        [string]::IsNullOrWhiteSpace($Discovery.EditionID) -or [int]$Discovery.BuildNumber -le 0 -or
        $Discovery.ProductType -notin @(1, 2, 3) -or $null -eq $Discovery.PSObject.Properties['Products']) {
        throw 'Windows OS and licensing discovery did not return the required profile fields.'
    }
    $builds = @{ 26100 = 2025; 20348 = 2022; 17763 = 2019; 14393 = 2016; 9600 = 2012 }
    $year = if ($builds.ContainsKey([int]$Discovery.BuildNumber)) { $builds[[int]$Discovery.BuildNumber] } else { 0 }
    $family = $Discovery.EditionID -replace '(?i)(ACor|Cor)$', ''
    $edition = switch ($family) {
        'ServerDatacenter' { 'Datacenter' }
        'ServerDatacenterAzureEdition' { 'DatacenterAzureEdition' }
        'ServerDatacenterAzure' { 'DatacenterAzureEdition' }
        'ServerStandard' { 'Standard' }
        'ServerSolution' { 'Essentials' }
        default { 'Unsupported' }
    }
    $current = @($Discovery.Products | Where-Object {
        ($_.LicenseFamily -replace '(?i)(ACor|Cor)$', '') -ieq $family
    })
    $issue = ''
    if ($current.Count -gt 1) {
        $issue = 'Multiple installed Windows licensing products match the current edition; no key will be replaced.'
    }
    elseif ($current.Count -eq 0 -and @($Discovery.Products).Count -gt 0) {
        $issue = 'Installed Windows license records do not match the current edition; no key will be replaced.'
    }
    elseif ($current.Count -eq 1 -and $current[0].LicenseStatus -notin @(0, 1, 2, 3, 4, 5, 6)) {
        $issue = 'The current edition licensing record has no valid LicenseStatus; no key will be replaced.'
    }
    [pscustomobject]@{
        Caption = $Discovery.Caption; BuildNumber = $Discovery.BuildNumber; Year = $year
        VersionLabel = if ($year -eq 2012) { '2012 R2' } else { [string]$year }
        EditionID = $Discovery.EditionID; LicenseFamily = $family; Edition = $edition
        IsServer = $Discovery.ProductType -in @(2, 3)
        IsEvaluation = $Discovery.EditionID -imatch 'Eval'
        LicenseStatus = if ($current.Count -eq 1) { $current[0].LicenseStatus } else { $null }
        DetectionIssue = $issue
    }
}

function Get-LabAVMAHostProfile {
    [void](Get-LabHostInfo)
    Get-LabWindowsAVMAProfile -Discovery (& $script:LabAVMAWindowsDiscovery)
}

function Get-LabAVMAActivationPlan {
    param([object]$HostProfile, [object]$GuestProfile)

    $reason = ''
    if (-not $GuestProfile.IsServer) { $reason = 'AVMA applies to Windows Server guests, not Windows client editions.' }
    elseif ($GuestProfile.IsEvaluation) { $reason = 'Evaluation guests are not converted or activated with an AVMA key; prepare a licensed, non-evaluation image.' }
    elseif (-not $script:LabAVMAKeys.ContainsKey([int]$GuestProfile.Year) -or
        -not $script:LabAVMAKeys[[int]$GuestProfile.Year].ContainsKey($GuestProfile.Edition)) {
        $reason = "No verified AVMA key is available for guest build $($GuestProfile.BuildNumber), edition '$($GuestProfile.EditionID)'."
    }
    elseif ($GuestProfile.DetectionIssue) { $reason = $GuestProfile.DetectionIssue }
    elseif (-not $HostProfile.IsServer -or $HostProfile.Edition -notin @('Datacenter', 'DatacenterAzureEdition') -or $HostProfile.IsEvaluation) {
        $reason = 'AVMA requires a non-evaluation Windows Server Datacenter Hyper-V host.'
    }
    elseif (-not $script:LabAVMAKeys.ContainsKey([int]$HostProfile.Year)) {
        $reason = "Host build $($HostProfile.BuildNumber) is not in the verified AVMA compatibility table."
    }
    elseif ($HostProfile.DetectionIssue) { $reason = "Host licensing cannot be verified: $($HostProfile.DetectionIssue)" }
    elseif ($null -eq $HostProfile.LicenseStatus -or $HostProfile.LicenseStatus -ne 1) {
        $reason = 'The current Windows Server Datacenter host license is not verified as Licensed (LicenseStatus 1).'
    }
    elseif ($GuestProfile.Year -gt $HostProfile.Year) {
        $reason = "Windows Server $($HostProfile.VersionLabel) cannot AVMA-activate a Windows Server $($GuestProfile.VersionLabel) guest."
    }
    if ($reason) {
        return [pscustomobject]@{ Action = 'Skipped'; Reason = $reason; Key = $null }
    }
    if ($GuestProfile.LicenseStatus -eq 1) {
        return [pscustomobject]@{ Action = 'AlreadyActivated'; Reason = 'The current guest Windows edition is already Licensed; its existing key is preserved.'; Key = $null }
    }
    [pscustomobject]@{
        Action = 'Activate'; Reason = 'Host and guest satisfy the verified AVMA version, edition and licensing requirements.'
        Key = $script:LabAVMAKeys[[int]$GuestProfile.Year][$GuestProfile.Edition]
    }
}

function Enable-LabAVMADataExchange {
    param([string]$VMName)

    $vm = @(Get-VM -Name $VMName -ErrorAction Stop | Where-Object Name -IEQ $VMName)
    if ($vm.Count -ne 1) { throw "Expected one exact VM named '$VMName' for AVMA Data Exchange." }
    $serviceId = '2a34b1c2-fd73-4043-8a5b-dd2159bc743f'
    $service = @(Get-VMIntegrationService -VM $vm[0] -ErrorAction Stop | Where-Object { $_.Id -match $serviceId })
    if ($service.Count -ne 1) { throw "Could not uniquely identify the Data Exchange integration service for '$VMName'." }
    if (-not $service[0].Enabled) {
        Enable-VMIntegrationService -VM $vm[0] -Name $service[0].Name -ErrorAction Stop
    }
    $verified = @(Get-VMIntegrationService -VM $vm[0] -ErrorAction Stop | Where-Object { $_.Id -match $serviceId })
    if ($verified.Count -ne 1 -or -not $verified[0].Enabled) { throw "AVMA Data Exchange is not enabled for '$VMName'." }
}

$script:LabAVMAActivateGuest = {
    param($Key, $ExpectedBuild, $ExpectedEdition, $ExpectedFamily, $DiscoverySource, $TimeoutSeconds)
    $ErrorActionPreference = 'Stop'
    $current = & ([scriptblock]::Create($DiscoverySource))
    if ($current.BuildNumber -ne $ExpectedBuild -or $current.EditionID -ine $ExpectedEdition -or $current.ProductType -notin @(2, 3)) {
        throw 'Guest OS version or edition changed before AVMA key installation.'
    }
    $licenses = @($current.Products | Where-Object {
        ($_.LicenseFamily -replace '(?i)(ACor|Cor)$', '') -ieq $ExpectedFamily
    })
    if ($licenses.Count -gt 1 -or ($licenses.Count -eq 0 -and @($current.Products).Count -gt 0)) {
        throw 'Current guest licensing is ambiguous; no key will be replaced.'
    }
    if ($licenses.Count -eq 1 -and $licenses[0].LicenseStatus -eq 1) {
        return [pscustomobject]@{ Status = 'AlreadyActivated'; LicenseStatus = 1; Verified = $true; Reason = 'Guest became Licensed before key installation; its existing key was preserved.' }
    }
    $kvp = Get-Service -Name vmickvpexchange -ErrorAction Stop
    if ([string]$kvp.Status -ne 'Running') { Start-Service -Name vmickvpexchange -ErrorAction Stop }
    if ([string](Get-Service -Name vmickvpexchange -ErrorAction Stop).Status -ne 'Running') {
        throw 'The guest Data Exchange service is not running; AVMA was not attempted.'
    }
    $emptyReturnOperations = [Collections.Generic.HashSet[string]]::new()
    function Assert-AVMAMethodResult {
        param($Result, [string]$Operation)
        if ($null -ne $Result -and $null -eq $Result.PSObject.Properties['ReturnValue']) {
            throw "$Operation returned an unexpected licensing result without a ReturnValue field."
        }
        if ($null -eq $Result -or $null -eq $Result.ReturnValue) {
            if ($emptyReturnOperations.Add($Operation)) {
                Write-Warning "$Operation returned no licensing status code. The installed AVMA product and final Licensed state must still be verified before reporting success."
            }
            return
        }
        if ($Result.ReturnValue -ne 0) { throw ('{0} failed with licensing code 0x{1:X8}.' -f $Operation, [long]$Result.ReturnValue) }
    }
    $service = Get-CimInstance -ClassName SoftwareLicensingService -Property Version -ErrorAction Stop
    $installed = Invoke-CimMethod -InputObject $service -MethodName InstallProductKey -Arguments @{ ProductKey = $Key } -ErrorAction Stop
    Assert-AVMAMethodResult -Result $installed -Operation 'AVMA key installation'
    $refreshed = Invoke-CimMethod -InputObject $service -MethodName RefreshLicenseStatus -ErrorAction Stop
    Assert-AVMAMethodResult -Result $refreshed -Operation 'License status refresh'
    $partialKey = $Key.Substring($Key.Length - 5)
    $filter = "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey='$partialKey' AND LicenseIsAddon=FALSE"
    $products = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $filter -ErrorAction Stop)
    if ($products.Count -ne 1) { throw 'The installed AVMA licensing product could not be uniquely identified.' }
    $productId = [string]$products[0].ID
    if (-not $productId) { throw 'The installed AVMA licensing product has no activation ID.' }
    if ($products[0].LicenseStatus -ne 1) {
        $activated = Invoke-CimMethod -InputObject $products[0] -MethodName Activate -ErrorAction Stop
        Assert-AVMAMethodResult -Result $activated -Operation 'AVMA activation'
    }
    $attempts = [int][Math]::Ceiling($TimeoutSeconds / 5) + 1
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $refreshed = Invoke-CimMethod -InputObject $service -MethodName RefreshLicenseStatus -ErrorAction Stop
        Assert-AVMAMethodResult -Result $refreshed -Operation 'License status refresh'
        $products = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter $filter -ErrorAction Stop)
        if ($products.Count -ne 1 -or [string]$products[0].ID -ine $productId) { throw 'AVMA licensing product identity changed during verification.' }
        if ($products[0].LicenseStatus -eq 1) {
            return [pscustomobject]@{ Status = 'Activated'; LicenseStatus = 1; Verified = $true; Reason = 'The selected AVMA licensing product is verified as Licensed.' }
        }
        if ($attempt -lt $attempts) { Start-Sleep -Seconds ([Math]::Min(5, $TimeoutSeconds - (($attempt - 1) * 5))) }
    }
    throw "AVMA did not reach Licensed status within $TimeoutSeconds seconds. Last LicenseStatus: $($products[0].LicenseStatus). Check guest event 12309 and host event 12310."
}

function Invoke-LabGuestAVMA {
    param([string]$VMName, [PSCredential]$Credential, [object]$HostProfile, [ValidateRange(1, 600)][int]$TimeoutSeconds = 120)

    $discovery = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock $script:LabAVMAWindowsDiscovery -ErrorAction Stop
    $guest = Get-LabWindowsAVMAProfile -Discovery $discovery
    $plan = Get-LabAVMAActivationPlan -HostProfile $HostProfile -GuestProfile $guest
    if ($plan.Action -eq 'Skipped') {
        Write-Warning "AVMA skipped for '$VMName': $($plan.Reason) Existing guest licensing was not changed."
        return [pscustomobject]@{ Status = 'Skipped'; Reason = $plan.Reason; LicenseStatus = $guest.LicenseStatus }
    }
    if ($plan.Action -eq 'AlreadyActivated') {
        Write-Host "Windows is already activated in '$VMName'; its existing product key was preserved."
        return [pscustomobject]@{ Status = 'AlreadyActivated'; Reason = $plan.Reason; LicenseStatus = 1 }
    }
    Enable-LabAVMADataExchange -VMName $VMName
    $result = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock $script:LabAVMAActivateGuest `
        -ArgumentList $plan.Key, $guest.BuildNumber, $guest.EditionID, $guest.LicenseFamily, $script:LabAVMAWindowsDiscovery.ToString(), $TimeoutSeconds -ErrorAction Stop
    if (@($result).Count -ne 1 -or $result.Verified -ne $true -or $result.LicenseStatus -ne 1 -or
        $result.Status -notin @('Activated', 'AlreadyActivated')) {
        throw "AVMA for '$VMName' did not return verified Licensed status."
    }
    Write-Host "Windows activation verified in '$VMName': $($result.Status)."
    $result
}

function Get-LabVMScopedLocalCredential {
    param([string]$VMName, [PSCredential]$Credential)

    $userName = ($Credential.UserName -split '\\')[-1] -replace '^\.', ''
    [PSCredential]::new("$VMName\$userName", $Credential.Password)
}

function Join-LabGuestDomain {
    param(
        [string]$VMName,
        [PSCredential]$LocalCredential,
        [PSCredential]$DomainCredential,
        [string]$DomainName,
        [string]$OUDistinguishedName,
        [string]$DomainControllerVMName,
        [int]$PowerShellDirectTimeoutSeconds,
        [string]$GuestTimeZone = 'India Standard Time'
    )

    $readGuestState = {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        [pscustomobject]@{
            ComputerName = $computer.Name
            PartOfDomain = $computer.PartOfDomain
            Domain = $computer.Domain
        }
    }
    $guestState = Invoke-Command -VMName $VMName -Credential $LocalCredential `
        -ScriptBlock $readGuestState -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($guestState.ComputerName)) {
        throw "Could not determine the current computer name in '$VMName'."
    }
    if ($guestState.PartOfDomain -and $guestState.Domain -ine $DomainName) {
        throw "Guest '$VMName' is already joined to '$($guestState.Domain)', not '$DomainName'."
    }

    $currentLocalCredential = Get-LabVMScopedLocalCredential -VMName $guestState.ComputerName -Credential $LocalCredential
    $renamedLocalCredential = Get-LabVMScopedLocalCredential -VMName $VMName -Credential $LocalCredential
    if ($guestState.ComputerName -ine $VMName) {
        Write-Host "Renaming guest '$($guestState.ComputerName)' to '$VMName' before continuing domain configuration."
        $renameResult = Invoke-Command -VMName $VMName -Credential $currentLocalCredential `
            -ArgumentList $VMName, $DomainName, $DomainCredential -ScriptBlock {
            param($TargetName, $TargetDomain, $JoinCredential)
            $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            $arguments = @{ NewName = $TargetName; PassThru = $true; Force = $true; ErrorAction = 'Stop' }
            if ($computer.PartOfDomain) {
                if ($computer.Domain -ine $TargetDomain) {
                    throw "Guest is already joined to '$($computer.Domain)', not '$TargetDomain'."
                }
                $arguments['DomainCredential'] = $JoinCredential
            }
            Rename-Computer @arguments
        } -ErrorAction Stop
        if (-not $renameResult.HasSucceeded) {
            throw "Computer rename did not report success for '$VMName'."
        }
        Restart-LabGuest -VMName $VMName -Credential $currentLocalCredential `
            -RestartCredential $renamedLocalCredential -TimeoutSeconds $PowerShellDirectTimeoutSeconds
        $currentLocalCredential = $renamedLocalCredential
    }

    if (-not $guestState.PartOfDomain) {
        $joinResult = Invoke-Command -VMName $VMName -Credential $currentLocalCredential `
            -ArgumentList $DomainName, $OUDistinguishedName, $VMName, $DomainCredential -ScriptBlock {
            param($TargetDomain, $TargetOU, $TargetName, $JoinCredential)
            $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            if ($computer.Name -ine $TargetName) {
                throw "Guest rename to '$TargetName' has not taken effect; domain join was not attempted."
            }
            if ($computer.PartOfDomain) {
                throw "Guest '$TargetName' is already joined to '$($computer.Domain)'."
            }
            Add-Computer -DomainName $TargetDomain -OUPath $TargetOU `
                -Credential $JoinCredential -PassThru -Force -ErrorAction Stop
        } -ErrorAction Stop
        if (-not $joinResult.HasSucceeded) {
            throw "Domain join did not report success for '$VMName'."
        }
        Restart-LabGuest -VMName $VMName -Credential $currentLocalCredential `
            -RestartCredential $renamedLocalCredential -TimeoutSeconds $PowerShellDirectTimeoutSeconds
    }
    else {
        Write-Host "Guest '$VMName' is already joined to '$DomainName'; verifying its name and OU without joining again."
    }

    Disable-LabGuestFirewall -VMName $VMName -Credential $renamedLocalCredential `
        -StabilizationSeconds 120 -RetryIntervalSeconds 15
    Set-LabGuestTimeZone -VMName $VMName -Credential $renamedLocalCredential `
        -TimeZoneId $GuestTimeZone

    $guestState = Invoke-Command -VMName $VMName -Credential $renamedLocalCredential `
        -ScriptBlock $readGuestState -ErrorAction Stop
    if ($guestState.ComputerName -ine $VMName -or -not $guestState.PartOfDomain -or
        $guestState.Domain -ine $DomainName) {
        throw "Guest '$VMName' did not return with the expected name and domain membership."
    }

    $adComputer = Invoke-Command -VMName $DomainControllerVMName -Credential $DomainCredential `
        -ArgumentList $VMName -ScriptBlock {
        param($ComputerName)
        Import-Module ActiveDirectory -ErrorAction Stop
        Get-ADComputer -Identity $ComputerName -Properties DistinguishedName -ErrorAction Stop |
            Select-Object Name, DistinguishedName
    } -ErrorAction Stop
    $parentPath = $adComputer.DistinguishedName.Substring(
        $adComputer.DistinguishedName.IndexOf(',') + 1
    )
    if ($parentPath -ine $OUDistinguishedName) {
        throw "Computer '$VMName' was created in '$parentPath', not '$OUDistinguishedName'."
    }
    return $guestState
}

function Invoke-HyperVLabConfiguredProvisioning {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$VMRoot,
        [string]$NamePrefix,
        [string]$DomainName,
        [string]$DomainControllerVMName,
        [string]$SubnetPrefix,
        [int]$PrefixLength,
        [string]$Gateway,
        [string]$DnsServer,
        [string]$GuestTimeZone = 'India Standard Time',
        [string]$OUBaseName,
        [string]$ExistingOUName,
        [string]$ManagementSwitchName,
        [string]$SmbSwitchName,
        [int]$PowerShellDirectTimeoutSeconds,
        [string[]]$ConfigureExistingVMName,
        [PSCredential]$LocalAdministratorCredential,
        [PSCredential]$DomainCredential
    )

    $ErrorActionPreference = 'Stop'
    Assert-LabNetworkSettings -SubnetPrefix $SubnetPrefix -Gateway $Gateway `
        -DnsServer $DnsServer -PrefixLength $PrefixLength
    if ($ManagementSwitchName -ieq $SmbSwitchName) {
        throw 'Management and SMB switch names must be different.'
    }

    $hasExistingVMs = $null -ne $ConfigureExistingVMName -and $ConfigureExistingVMName.Count -gt 0
    if ($WhatIfPreference -and $hasExistingVMs) {
        foreach ($vmName in $ConfigureExistingVMName) {
            [void]$PSCmdlet.ShouldProcess($vmName, 'Configure guest networking and join the domain')
        }
        return
    }
    $needsDerivedOU = [string]::IsNullOrWhiteSpace($OUBaseName) -and [string]::IsNullOrWhiteSpace($ExistingOUName)
    if (-not $hasExistingVMs -or $needsDerivedOU) {
        if ([string]::IsNullOrWhiteSpace($NamePrefix)) {
            $NamePrefix = Read-LabNamePrefix
        }
        Assert-LabNamePrefix -Prefix $NamePrefix
    }
    if ($needsDerivedOU) {
        $OUBaseName = Get-LabOUBaseName -NamePrefix $NamePrefix
    }
    if ([string]::IsNullOrWhiteSpace($ExistingOUName)) {
        Write-Host "Deployment OU base: '$OUBaseName' (first unused name: base, base01, base02, ...; allocated on the DC during creation)."
    }
    if ($WhatIfPreference) {
        return Invoke-HyperVLabProvisioning -VMRoot $VMRoot -NamePrefix $NamePrefix `
            -StartVMs $true -WhatIf
    }

    $avmaHost = Get-LabAVMAHostProfile
    Write-Host "AVMA host detection: $($avmaHost.Caption), edition '$($avmaHost.EditionID)', LicenseStatus '$($avmaHost.LicenseStatus)'."
    if ($null -eq $LocalAdministratorCredential) {
        $LocalAdministratorCredential = Read-LabCredential -UserName 'Administrator' `
            -Message 'Enter the guest local Administrator credential. For a resumed domain member, use its current Windows hostname (CURRENT-WINDOWS-NAME\Administrator), not the Hyper-V VM name or host account.'
    }
    if ($null -eq $DomainCredential) {
        $DomainCredential = Read-LabCredential -UserName '' `
            -Message "Enter an account allowed to create OUs and join computers to '$DomainName'."
    }

    [void](Test-LabDomainController -VMName $DomainControllerVMName -DomainName $DomainName `
        -DnsServer $DnsServer -Credential $DomainCredential)
    $createdVMs = @(if ($hasExistingVMs) {
        $uniqueNames = @($ConfigureExistingVMName | Sort-Object -Unique)
        foreach ($requestedName in $uniqueNames) {
            if ($requestedName -ieq $DomainControllerVMName) {
                throw "Domain controller VM '$DomainControllerVMName' cannot be configured as a new lab node."
            }
            $matches = @(Get-VM -Name $requestedName -ErrorAction Stop |
                Where-Object { $_.Name -ieq $requestedName })
            if ($matches.Count -ne 1) {
                throw "Expected exactly one existing VM named '$requestedName'."
            }
            if ([string]$matches[0].State -ieq 'Off') {
                Start-VM -VM $matches[0] -ErrorAction Stop
            }
            elseif ([string]$matches[0].State -ine 'Running') {
                throw "Existing VM '$requestedName' must be Off or Running, not '$($matches[0].State)'."
            }
            $matches[0]
        }
    }
    else {
        @(Invoke-HyperVLabProvisioning -VMRoot $VMRoot -NamePrefix $NamePrefix -StartVMs $true)
    })
    if ($createdVMs.Count -eq 0) {
        Write-Host 'No VMs were created; guest configuration was skipped.'
        return
    }

    $currentName = ''
    try {
        foreach ($vm in $createdVMs) {
            $currentName = $vm.Name
            Wait-LabPowerShellDirect -VMName $vm.Name -Credential $LocalAdministratorCredential `
                -TimeoutSeconds $PowerShellDirectTimeoutSeconds -FailOnInvalidCredential:$hasExistingVMs
            Enable-LabGuestHypervisor -VMName $vm.Name -Credential $LocalAdministratorCredential `
                -TimeoutSeconds $PowerShellDirectTimeoutSeconds
            Disable-LabGuestFirewall -VMName $vm.Name -Credential $LocalAdministratorCredential
            Set-LabGuestTimeZone -VMName $vm.Name -Credential $LocalAdministratorCredential `
                -TimeZoneId $GuestTimeZone
        }

        $addresses = @(Get-LabAvailableIPv4Addresses -RequiredCount $createdVMs.Count `
            -SubnetPrefix $SubnetPrefix -Gateway $Gateway -DnsServer $DnsServer `
            -DomainName $DomainName -DomainControllerVMName $DomainControllerVMName `
            -DomainCredential $DomainCredential)
        $ou = if ([string]::IsNullOrWhiteSpace($ExistingOUName)) {
            $newOU = New-LabSerializedOU -DomainControllerVMName $DomainControllerVMName `
                -DomainName $DomainName -BaseName $OUBaseName -Credential $DomainCredential
            Write-Host "Created OU '$($newOU.Name)' at '$($newOU.DistinguishedName)'."
            $newOU
        }
        else {
            $existingOU = Get-LabExistingOU -DomainControllerVMName $DomainControllerVMName `
                -DomainName $DomainName -Name $ExistingOUName -Credential $DomainCredential
            Write-Host "Using existing OU '$($existingOU.Name)' at '$($existingOU.DistinguishedName)'."
            $existingOU
        }

        $results = @()
        for ($index = 0; $index -lt $createdVMs.Count; $index++) {
            $vm = $createdVMs[$index]
            $currentName = $vm.Name
            $adapterPlan = @(Get-LabGuestAdapterPlan -VMName $vm.Name `
                -ManagementSwitchName $ManagementSwitchName -SmbSwitchName $SmbSwitchName)
            [void](Invoke-LabGuestNetworkConfiguration -VMName $vm.Name `
                -Credential $LocalAdministratorCredential -AdapterPlan $adapterPlan `
                -IPAddress $addresses[$index] -PrefixLength $PrefixLength -Gateway $Gateway `
                -DnsServer $DnsServer -DomainName $DomainName)
            $joined = Join-LabGuestDomain -VMName $vm.Name `
                -LocalCredential $LocalAdministratorCredential -DomainCredential $DomainCredential `
                -DomainName $DomainName -OUDistinguishedName $ou.DistinguishedName `
                -DomainControllerVMName $DomainControllerVMName `
                -PowerShellDirectTimeoutSeconds $PowerShellDirectTimeoutSeconds `
                -GuestTimeZone $GuestTimeZone
            $activationCredential = Get-LabVMScopedLocalCredential -VMName $vm.Name -Credential $LocalAdministratorCredential
            $activation = Invoke-LabGuestAVMA -VMName $vm.Name -Credential $activationCredential -HostProfile $avmaHost
            $results += [pscustomobject]@{
                VMName = $vm.Name
                IPAddress = $addresses[$index]
                Domain = $joined.Domain
                OU = $ou.Name
                ActivationStatus = $activation.Status
                ActivationReason = $activation.Reason
                LicenseStatus = $activation.LicenseStatus
            }
            Write-Host "Configured $($vm.Name) as $($addresses[$index]) and joined it to $DomainName."
        }
        return $results
    }
    catch {
        throw "Post-provisioning configuration stopped at '$currentName': $($_.Exception.Message) Completed changes were preserved for inspection."
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-HyperVLabConfiguredProvisioning -VMRoot $VMRoot -NamePrefix $NamePrefix `
        -DomainName $DomainName -DomainControllerVMName $DomainControllerVMName `
        -SubnetPrefix $SubnetPrefix -PrefixLength $PrefixLength -Gateway $Gateway `
        -DnsServer $DnsServer -GuestTimeZone $GuestTimeZone -OUBaseName $OUBaseName `
        -ExistingOUName $ExistingOUName `
        -ManagementSwitchName $ManagementSwitchName -SmbSwitchName $SmbSwitchName `
        -PowerShellDirectTimeoutSeconds $PowerShellDirectTimeoutSeconds `
        -ConfigureExistingVMName $ConfigureExistingVMName `
        -LocalAdministratorCredential $LocalAdministratorCredential `
        -DomainCredential $DomainCredential -WhatIf:$WhatIfPreference
}
