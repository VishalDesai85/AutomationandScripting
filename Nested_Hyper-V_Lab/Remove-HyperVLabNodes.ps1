#requires -Version 5.1
<#
.SYNOPSIS
Unjoins and removes explicitly selected Hyper-V lab member servers and their storage.
.DESCRIPTION
Run on the Hyper-V host. Uses PowerShell Direct for guest, cluster, AD and DNS work.
WhatIf performs discovery only. A typed confirmation is always required for deletion.
.EXAMPLE
.\Remove-HyperVLabNodes.ps1 -NodeName HypNode1,HypNode2 -WhatIf
.EXAMPLE
.\Remove-HyperVLabNodes.ps1 -NodeName HypNode1,HypNode2 -DomainControllerVMName MylabAD01
.EXAMPLE
.\Remove-HyperVLabNodes.ps1 -NodeName HypNode1,HypNode2 -CleanupMode Recovery -DomainName mylab.local -DomainControllerVMName MylabAD01 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string[]]$NodeName,
    [string]$VMRoot = 'D:\HyperV',
    [string]$DomainControllerVMName,
    [string[]]$ProtectedVMName = @('MylabAD01'),
    [ValidateSet('Standard', 'VMOnly', 'Recovery')]
    [string]$CleanupMode,
    [ValidatePattern('^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$')]
    [string]$DomainName,
    [switch]$AllowComputerSubtreeRemoval,
    [PSCredential]$NodeCredential,
    [PSCredential]$DomainCredential,
    [ValidateRange(60, 3600)]
    [int]$ClusterTimeoutSeconds = 600
)

function ConvertTo-LabCleanupNames {
    param([string[]]$Names)

    $result = @($Names | ForEach-Object { $_ -split '[,\s;]+' } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($result.Count -eq 0) {
        throw 'Specify at least one exact VM name.'
    }
    foreach ($name in $result) {
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$') {
            throw "Invalid node name '$name'. Wildcards, paths and ranges are not accepted."
        }
    }
    return $result
}

function Get-LabCleanupPath {
    param([string]$Path)

    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path -match '[*?\[\]]') {
        throw "Only fully qualified local filesystem paths are supported: '$Path'."
    }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-LabCleanupPathWithin {
    param([string]$Path, [string]$Folder)

    $pathValue = Get-LabCleanupPath $Path
    $folderValue = Get-LabCleanupPath $Folder
    return $pathValue.Equals($folderValue, [StringComparison]::OrdinalIgnoreCase) -or
        $pathValue.StartsWith("$folderValue\", [StringComparison]::OrdinalIgnoreCase)
}

function Assert-LabCleanupFolder {
    param([string]$Folder, [string]$Root, [string]$Name)

    $resolved = Get-LabCleanupPath $Folder
    $rootPath = Get-LabCleanupPath $Root
    if ($rootPath.Length -le 3 -or $resolved -ine (Join-Path $rootPath $Name)) {
        throw "Refusing unsafe deletion folder '$Folder'. Expected a VM-named child of '$Root'."
    }
    foreach ($protected in @($HOME, $PSScriptRoot, (Get-Location).Path, $env:SystemRoot, $env:ProgramFiles)) {
        if ($protected -and (Test-LabCleanupPathWithin -Path $protected -Folder $resolved)) {
            throw "Deletion folder '$Folder' contains a protected host/workspace path."
        }
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "VM folder '$resolved' is missing or is not a directory."
    }
    $ancestor = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    while ($null -ne $ancestor) {
        if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing reparse point '$($ancestor.FullName)'."
        }
        $ancestor = $ancestor.Parent
    }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($resolved)
    while ($pending.Count -gt 0) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing reparse point '$($item.FullName)' inside the VM folder."
            }
            if ($item.PSIsContainer) {
                $pending.Push($item.FullName)
            }
        }
    }
}

function Get-LabCleanupVMDisks {
    param([object]$VM)

    Get-VMHardDiskDrive -VM $VM -ErrorAction Stop
    foreach ($snapshot in @(Get-VMSnapshot -VM $VM -ErrorAction Stop)) {
        Get-VMHardDiskDrive -VMSnapshot $snapshot -ErrorAction Stop
    }
}

function Get-LabCleanupDiskChain {
    param([string]$Path)

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    while ($Path) {
        $Path = Get-LabCleanupPath $Path
        if (-not $seen.Add($Path)) {
            throw "Circular VHD chain detected at '$Path'."
        }
        $Path
        $disk = Get-VHD -Path $Path -ErrorAction Stop
        $Path = $disk.ParentPath
    }
}

function Get-LabCleanupStorage {
    param([object[]]$SelectedVMs, [object[]]$AllVMs, [string]$Root)

    $plans = @(
        foreach ($vm in $SelectedVMs) {
            $folder = Join-Path (Get-LabCleanupPath $Root) $vm.Name
            Assert-LabCleanupFolder -Folder $folder -Root $Root -Name $vm.Name
            foreach ($path in @($vm.Path, $vm.ConfigurationLocation, $vm.SnapshotFileLocation, $vm.SmartPagingFilePath)) {
                if ($path -and -not (Test-LabCleanupPathWithin -Path $path -Folder $folder)) {
                    throw "VM '$($vm.Name)' has configuration outside '$folder': '$path'."
                }
            }
            $diskPaths = @(
                foreach ($drive in @(Get-LabCleanupVMDisks -VM $vm)) {
                    if (-not $drive.Path -or [IO.Path]::GetExtension($drive.Path) -notin @('.vhdx', '.avhdx')) {
                        throw "VM '$($vm.Name)' has a pass-through/shared/unsupported disk. Manual cleanup is required."
                    }
                    if (-not (Test-LabCleanupPathWithin -Path $drive.Path -Folder $folder)) {
                        throw "VM '$($vm.Name)' has a disk outside its dedicated folder: '$($drive.Path)'."
                    }
                    Get-LabCleanupDiskChain -Path $drive.Path
                }
            )
            [pscustomobject]@{ VMId = $vm.Id; VMName = $vm.Name; Folder = $folder; DiskPaths = @($diskPaths | Sort-Object -Unique) }
        }
    )
    Assert-LabCleanupStorageReferences -Plans $plans -AllVMs $AllVMs
    return $plans
}

function Assert-LabCleanupStorageReferences {
    param([object[]]$Plans, [object[]]$AllVMs)

    foreach ($vm in $AllVMs) {
        $paths = @($vm.Path, $vm.ConfigurationLocation, $vm.SnapshotFileLocation, $vm.SmartPagingFilePath)
        $paths += @(
            foreach ($drive in @(Get-LabCleanupVMDisks -VM $vm)) {
                if ($drive.Path) {
                    Get-LabCleanupDiskChain -Path $drive.Path
                }
            }
        )
        foreach ($plan in $Plans) {
            if ($vm.Id -eq $plan.VMId) {
                continue
            }
            foreach ($path in $paths) {
                if ($path -and (Test-LabCleanupPathWithin -Path $path -Folder $plan.Folder)) {
                    throw "VM '$($vm.Name)' or its backing/checkpoint chain references '$($plan.Folder)'. Storage is shared; cleanup is blocked."
                }
            }
        }
    }
}

$script:LabCleanupGuestDiscovery = {
    $ErrorActionPreference = 'Stop'
    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if ($computer.DomainRole -ge 4) {
        throw 'Domain controllers cannot be cleaned up by this member-server script.'
    }
    $interfaces = @(Get-NetIPConfiguration -ErrorAction Stop | Sort-Object -Property @{
        Expression = { if ($_.IPv4DefaultGateway) { 0 } else { 1 } }
    })
    $dns = @(
        foreach ($interface in $interfaces) {
            Get-DnsClientServerAddress -InterfaceIndex $interface.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
                Select-Object -ExpandProperty ServerAddresses
        }
    )
    $dcHosts = @()
    if ($computer.PartOfDomain) {
        if ($dns.Count -eq 0) {
            throw 'The domain member has no IPv4 DNS server configured.'
        }
        $dcHosts = @(Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$($computer.Domain)" -Type SRV `
            -Server $dns[0] -DnsOnly -ErrorAction Stop | Where-Object Type -EQ 'SRV' |
            Select-Object -ExpandProperty NameTarget)
        if ($dcHosts.Count -eq 0) {
            throw 'Primary DNS did not return any AD domain controllers.'
        }
    }
    $clusterInfo = $null
    if (Test-Path -LiteralPath 'HKLM:\Cluster') {
        Import-Module FailoverClusters -ErrorAction Stop
        $cluster = Get-Cluster -ErrorAction Stop
        $members = @(Get-ClusterNode -ErrorAction Stop | Select-Object -ExpandProperty Name)
        $identities = @(
            foreach ($resource in @(Get-ClusterResource -ErrorAction Stop |
                Where-Object { [string]$_.ResourceType -in @('Network Name', 'Distributed Network Name') })) {
                $properties = @($resource | Get-ClusterParameter -ErrorAction Stop)
                $dnsName = @($properties | Where-Object Name -EQ 'DnsName' | Select-Object -ExpandProperty Value)
                $netName = @($properties | Where-Object Name -EQ 'Name' | Select-Object -ExpandProperty Value)
                $guid = @($properties | Where-Object Name -EQ 'ObjectGUID' | Select-Object -ExpandProperty Value)
                $name = if ($dnsName.Count -gt 0 -and $dnsName[0]) { [string]$dnsName[0] }
                    elseif ($netName.Count -gt 0 -and $netName[0]) { [string]$netName[0] }
                    else { throw "Cannot identify DNS name for cluster resource '$($resource.Name)'." }
                [pscustomobject]@{ Name = $name; ObjectGUID = if ($guid.Count -gt 0) { [string]$guid[0] } else { '' } }
            }
        )
        $clusterInfo = [pscustomobject]@{
            Name = $cluster.Name
            Members = $members
            S2DEnabled = [bool]$cluster.S2DEnabled
            Identities = $identities
        }
    }
    [pscustomobject]@{
        ComputerName = $computer.Name
        Domain = $computer.Domain
        PartOfDomain = [bool]$computer.PartOfDomain
        PrimaryDns = if ($dns.Count -gt 0) { $dns[0] } else { '' }
        DomainControllerHosts = $dcHosts
        Cluster = $clusterInfo
    }
}

function Get-LabCleanupClusters {
    param([object[]]$Nodes)

    $selectedNames = @($Nodes | ForEach-Object { $_.Guest.ComputerName })
    foreach ($group in @($Nodes | Where-Object { $null -ne $_.Guest.Cluster } |
        Group-Object -Property { $_.Guest.Cluster.Name })) {
        $info = $group.Group[0].Guest.Cluster
        $expected = @($info.Members | ForEach-Object { ($_ -split '\.')[0] } | Sort-Object -Unique)
        if ($expected.Count -eq 0) {
            throw "Cluster '$($info.Name)' has no discoverable members."
        }
        foreach ($node in $group.Group) {
            $reported = @($node.Guest.Cluster.Members | ForEach-Object { ($_ -split '\.')[0] } | Sort-Object -Unique)
            if (($reported -join ',') -ine ($expected -join ',') -or $expected -inotcontains $node.Guest.ComputerName) {
                throw "Inconsistent membership reported for cluster '$($info.Name)'."
            }
        }
        $remaining = @($expected | Where-Object { $selectedNames -inotcontains $_ })
        if ($remaining.Count -gt 0 -and $info.S2DEnabled) {
            throw "Partial removal from Storage Spaces Direct cluster '$($info.Name)' requires manual storage retirement."
        }
        if ($remaining.Count -eq 0 -and @($info.Identities | Where-Object {
            ($_.Name -split '\.')[0] -ieq ($info.Name -split '\.')[0]
        }).Count -ne 1) {
            throw "Cannot uniquely identify the cluster network-name identity for '$($info.Name)'."
        }
        [pscustomobject]@{
            Name = $info.Name
            VMId = $group.Group[0].VM.Id
            Members = $expected
            SelectedMembers = @($group.Group | ForEach-Object { $_.Guest.ComputerName })
            Action = if ($remaining.Count -eq 0) { 'Destroy' } else { 'Evict' }
            Identities = @($info.Identities)
            DomainJoined = [bool]$group.Group[0].Guest.PartOfDomain
        }
    }
}

function Get-LabCleanupTargets {
    param([object[]]$Nodes, [object[]]$Clusters, [string]$Domain)

    $targets = @(
        foreach ($node in $Nodes) {
            [pscustomobject]@{ Name = $node.Guest.ComputerName; Kind = 'Node'; ObjectGUID = '' }
        }
        foreach ($cluster in @($Clusters | Where-Object Action -EQ 'Destroy')) {
            foreach ($identity in $cluster.Identities) {
                [pscustomobject]@{ Name = $identity.Name; Kind = 'Cluster'; ObjectGUID = $identity.ObjectGUID }
            }
        }
    )
    foreach ($target in $targets) {
        $short = ($target.Name -split '\.')[0]
        $fqdn = if ($target.Name.Contains('.')) { $target.Name.TrimEnd('.') } else { "$short.$Domain" }
        if ($short -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$' -or $fqdn -ine "$short.$Domain") {
            throw "Identity '$($target.Name)' is not an exact computer name in '$Domain'."
        }
        [pscustomobject]@{ Name = $short; Fqdn = $fqdn; Kind = $target.Kind; ObjectGUID = $target.ObjectGUID }
    }
}

# Executed on the DC, so AD and DNS cmdlets use its local services, not a second hop.
$script:LabCleanupDirectory = {
    param($Mode, $Domain, $Targets, $ExpectedComputers, [bool]$AllowSubtreeRemoval = $false)
    $ErrorActionPreference = 'Stop'
    Import-Module ActiveDirectory -ErrorAction Stop
    Import-Module DnsServer -ErrorAction Stop
    $system = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $adDomain = Get-ADDomain -Identity $Domain -Server $env:COMPUTERNAME -ErrorAction Stop
    if ($system.DomainRole -lt 4 -or $adDomain.DNSRoot -ine $Domain -or $system.Domain -ine $Domain) {
        throw "The selected DC does not host '$Domain'."
    }
    $computerPlans = @(
        foreach ($target in $Targets) {
            if ($target.Name -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$' -or $target.Fqdn -ine "$($target.Name).$Domain") {
                throw 'Invalid directory cleanup target.'
            }
            if ($target.Name -ieq $env:COMPUTERNAME) {
                throw 'The domain controller cannot be a directory cleanup target.'
            }
            $account = @(Get-ADComputer -LDAPFilter "(sAMAccountName=$($target.Name)`$)" -Server $env:COMPUTERNAME `
                -Properties DNSHostName, userAccountControl -ErrorAction Stop)
            if ($account.Count -gt 1) {
                throw "Ambiguous computer account '$($target.Name)'."
            }
            $guid = ''
            $distinguishedName = ''
            $children = @()
            if ($account.Count -eq 1) {
                if (($account[0].userAccountControl -band 8192) -or $account[0].DNSHostName -ine $target.Fqdn) {
                    throw "Computer '$($target.Name)' is a DC or has an unexpected DNS identity."
                }
                $guid = [string]$account[0].ObjectGUID
                if ($target.Kind -eq 'Cluster' -and (-not $target.ObjectGUID -or $guid -ine $target.ObjectGUID.Trim('{}'))) {
                    throw "Cluster account '$($target.Name)' is not verified by its network-name resource GUID."
                }
                if ($target.Kind -eq 'Recovery' -and -not ($account[0].userAccountControl -band 2)) {
                    throw "Recovery requires a disabled AD account for '$($target.Name)'. It may still be an active domain member; inspect it before proceeding."
                }
                $distinguishedName = [string]$account[0].DistinguishedName
                if (-not $distinguishedName) { throw "Missing AD distinguished name for '$($target.Name)'." }
                $subtree = @(Get-ADObject -SearchBase $distinguishedName -SearchScope Subtree -Filter * `
                    -Properties ProtectedFromAccidentalDeletion -Server $env:COMPUTERNAME -ErrorAction Stop)
                $root = @($subtree | Where-Object { [string]$_.ObjectGUID -ieq $guid })
                if ($root.Count -ne 1 -or $root[0].ObjectClass -ine 'computer' -or
                    $root[0].DistinguishedName -ine $distinguishedName) {
                    throw "Cannot verify the computer-only subtree root for '$($target.Name)'."
                }
                foreach ($entry in $subtree) {
                    if ($entry.ProtectedFromAccidentalDeletion -isnot [bool] -or $entry.ProtectedFromAccidentalDeletion) {
                        throw "AD object '$($entry.DistinguishedName)' is protected or its protection cannot be verified. No protection flags will be changed automatically."
                    }
                    if ([string]$entry.ObjectGUID -ieq $guid) { continue }
                    if (-not $entry.DistinguishedName.EndsWith(",$distinguishedName", [StringComparison]::OrdinalIgnoreCase) -or
                        $entry.ObjectClass -in @('computer', 'organizationalUnit', 'domainDNS', 'user', 'group')) {
                        throw "Unexpected child '$($entry.DistinguishedName)' prevents computer-subtree cleanup."
                    }
                    $children += [pscustomobject]@{
                        ObjectGUID = [string]([guid]$entry.ObjectGUID)
                        DistinguishedName = [string]$entry.DistinguishedName
                        ObjectClass = [string]$entry.ObjectClass
                    }
                }
            }
            if ($Mode -eq 'Remove') {
                $expected = @($ExpectedComputers | Where-Object Name -IEQ $target.Name)
                if ($expected.Count -ne 1 -or ($guid -and $guid -ine $expected[0].ObjectGUID)) {
                    throw "Computer account '$($target.Name)' changed since preview. No replacement account will be deleted."
                }
                if ($guid) {
                    if ($distinguishedName -ine $expected[0].DistinguishedName) {
                        throw "Computer account '$($target.Name)' moved since preview."
                    }
                    $approvedChildren = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                    foreach ($child in @($expected[0].Children)) {
                        [void]$approvedChildren.Add("$($child.ObjectGUID)|$($child.DistinguishedName)|$($child.ObjectClass)")
                    }
                    foreach ($child in $children) {
                        if (-not $approvedChildren.Contains("$($child.ObjectGUID)|$($child.DistinguishedName)|$($child.ObjectClass)")) {
                            throw "Computer account '$($target.Name)' has new or changed child objects since preview. Review a new plan before deleting."
                        }
                    }
                    if ($children.Count -gt 0 -and -not $AllowSubtreeRemoval) {
                        throw "Computer account '$($target.Name)' has child objects; explicit computer-subtree deletion approval is required."
                    }
                }
            }
            [pscustomobject]@{
                Name = $target.Name; Fqdn = $target.Fqdn; ObjectGUID = $guid
                DistinguishedName = $distinguishedName; Children = $children
                State = if ($guid) { 'Present' } else { 'Already absent' }
            }
        }
    )

    $zones = @(Get-DnsServerZone -ErrorAction Stop)
    if (@($zones | Where-Object { $_.ZoneName -ieq $Domain -and [string]$_.ZoneType -eq 'Primary' }).Count -ne 1) {
        throw "The selected DC does not host a writable DNS zone for '$Domain'."
    }
    function Get-MatchingCleanupDnsRecords {
        $fqdnNames = @($Targets | ForEach-Object { $_.Fqdn.TrimEnd('.').ToLowerInvariant() })
        foreach ($zone in $zones) {
            if ([string]$zone.ZoneType -ne 'Primary' -or $zone.IsAutoCreated) { continue }
            foreach ($record in @(Get-DnsServerResourceRecord -ZoneName $zone.ZoneName -ErrorAction Stop)) {
                $owner = if ($record.HostName -eq '@') { $zone.ZoneName } else { "$($record.HostName).$($zone.ZoneName)" }
                $destination = switch ([string]$record.RecordType) {
                    'PTR' { [string]$record.RecordData.PtrDomainName }
                    'CNAME' { [string]$record.RecordData.HostNameAlias }
                    'SRV' { [string]$record.RecordData.DomainName }
                    'NS' { [string]$record.RecordData.NameServer }
                    'SOA' { [string]$record.RecordData.PrimaryServer }
                    default { '' }
                }
                $ownerMatch = $fqdnNames -contains $owner.TrimEnd('.').ToLowerInvariant()
                $targetMatch = $destination -and $fqdnNames -contains $destination.TrimEnd('.').ToLowerInvariant()
                if ($ownerMatch -or $targetMatch) {
                    if ([string]$record.RecordType -in @('NS', 'SOA')) {
                        throw "Target '$owner' is referenced by a zone's NS/SOA record. Manual DNS review is required."
                    }
                    [pscustomobject]@{ Zone = $zone.ZoneName; Owner = $owner; Type = [string]$record.RecordType; Record = $record }
                }
            }
        }
    }

    $records = @(Get-MatchingCleanupDnsRecords)
    if ($Mode -eq 'Discover') {
        return [pscustomobject]@{
            DCName = $system.Name
            Computers = $computerPlans
            DnsRecords = @($records | Select-Object Zone, Owner, Type)
        }
    }
    if ($Mode -ne 'Remove') { throw "Unknown directory operation '$Mode'." }
    foreach ($computer in $computerPlans) {
        if ($computer.ObjectGUID) {
            if ($computer.Children.Count -gt 0) {
                Remove-ADObject -Identity ([guid]$computer.ObjectGUID) -Recursive -Server $env:COMPUTERNAME -Confirm:$false -ErrorAction Stop
            }
            else {
                Remove-ADComputer -Identity ([guid]$computer.ObjectGUID) -Server $env:COMPUTERNAME -Confirm:$false -ErrorAction Stop
            }
        }
    }
    foreach ($entry in $records) {
        Remove-DnsServerResourceRecord -ZoneName $entry.Zone -InputObject $entry.Record -Force -ErrorAction Stop
    }
    foreach ($target in $Targets) {
        if (@(Get-ADComputer -LDAPFilter "(sAMAccountName=$($target.Name)`$)" -Server $env:COMPUTERNAME -ErrorAction Stop).Count -gt 0) {
            throw "Computer account '$($target.Name)' still exists after cleanup."
        }
    }
    if (@(Get-MatchingCleanupDnsRecords).Count -gt 0) {
        throw 'Matching DNS records remain after cleanup.'
    }
    [pscustomobject]@{ Verified = $true; RemovedComputerCount = @($computerPlans | Where-Object ObjectGUID).Count; RemovedDnsCount = $records.Count }
}

$script:LabCleanupClusterWorker = {
    param($Plan)
    $ErrorActionPreference = 'Stop'
    Import-Module FailoverClusters -ErrorAction Stop
    $members = @(Get-ClusterNode -Cluster $Plan.Name -ErrorAction Stop |
        ForEach-Object { ($_.Name -split '\.')[0] } | Sort-Object -Unique)
    if (($members -join ',') -ine ($Plan.Members -join ',')) {
        throw "Cluster '$($Plan.Name)' membership changed since preview."
    }
    if ($Plan.Action -eq 'Destroy') {
        if (@($members | Where-Object { $Plan.SelectedMembers -inotcontains $_ }).Count -gt 0) {
            throw 'Cannot destroy a cluster with unselected members.'
        }
        # AD deletion is performed separately on the DC with exact, preflighted GUIDs.
        Remove-Cluster -Cluster $Plan.Name -Force -ErrorAction Stop
        if (Test-Path -LiteralPath 'HKLM:\Cluster') {
            throw 'Local cluster configuration remains after cluster destruction.'
        }
    }
    elseif ($Plan.Action -eq 'Evict') {
        $ordered = @($Plan.SelectedMembers | Where-Object { $_ -ine $env:COMPUTERNAME })
        $ordered += @($Plan.SelectedMembers | Where-Object { $_ -ieq $env:COMPUTERNAME })
        foreach ($name in $ordered) {
            Suspend-ClusterNode -Cluster $Plan.Name -Name $name -Drain -Wait -ErrorAction Stop | Out-Null
            $owned = @(Get-ClusterGroup -Cluster $Plan.Name -ErrorAction Stop | Where-Object {
                ($_.OwnerNode.Name -split '\.')[0] -ieq $name
            })
            if ($owned.Count -gt 0) {
                throw "Cluster groups still run on '$name'. Eviction is blocked."
            }
            Remove-ClusterNode -Cluster $Plan.Name -Name $name -Force -ErrorAction Stop
        }
        $remaining = @(Get-ClusterNode -Cluster $Plan.Name -ErrorAction Stop | ForEach-Object { ($_.Name -split '\.')[0] })
        if (@($remaining | Where-Object { $Plan.SelectedMembers -icontains $_ }).Count -gt 0) {
            throw 'Selected cluster nodes remain after eviction.'
        }
    }
    else { throw "Invalid cluster action '$($Plan.Action)'." }
    [pscustomobject]@{ Verified = $true }
}

function Invoke-LabCleanupCluster {
    param([object]$Plan, [PSCredential]$NodeCredential, [PSCredential]$DomainCredential, [int]$TimeoutSeconds)

    # A fresh credentialed local process avoids cluster cmdlets' remoting double-hop restriction.
    $result = Invoke-Command -VMId $Plan.VMId -Credential $NodeCredential -ArgumentList `
        $Plan, $DomainCredential, $script:LabCleanupClusterWorker.ToString(), $TimeoutSeconds -ScriptBlock {
        param($ClusterPlan, $Credential, $WorkerSource, $Timeout)
        $ErrorActionPreference = 'Stop'
        $job = Start-Job -Credential $Credential -ScriptBlock ([scriptblock]::Create($WorkerSource)) -ArgumentList $ClusterPlan -ErrorAction Stop
        try {
            $completed = Wait-Job -Job $job -Timeout $Timeout -ErrorAction Stop
            if (-not $completed -or [string]$job.State -ne 'Completed') {
                throw "Cluster worker timed out or failed (state: $($job.State)). $($job.ChildJobs[0].JobStateInfo.Reason)"
            }
            Receive-Job -Job $job -ErrorAction Stop
        }
        finally {
            if ([string]$job.State -eq 'Running') {
                Stop-Job -Job $job -ErrorAction Stop
            }
            Remove-Job -Job $job -Force -ErrorAction Stop
        }
    } -ErrorAction Stop
    if (@($result).Count -ne 1 -or $result.Verified -ne $true) {
        throw "Cluster '$($Plan.Name)' cleanup did not return verified completion."
    }
}

function Invoke-LabCleanupUnjoin {
    param([object]$Node, [PSCredential]$NodeCredential, [PSCredential]$DomainCredential)

    $result = Invoke-Command -VMId $Node.VM.Id -Credential $NodeCredential -ArgumentList `
        $Node.Guest.ComputerName, $Node.Guest.Domain, $DomainCredential -ScriptBlock {
        param($ExpectedName, $ExpectedDomain, $Credential)
        $ErrorActionPreference = 'Stop'
        $system = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($system.Name -ine $ExpectedName -or $system.DomainRole -ge 4) {
            throw 'Guest identity changed or guest is a domain controller.'
        }
        if ($system.PartOfDomain) {
            if ($system.Domain -ine $ExpectedDomain) { throw 'Guest domain changed since preview.' }
            $change = Remove-Computer -UnjoinDomainCredential $Credential -WorkgroupName 'WORKGROUP' -Force -PassThru -ErrorAction Stop
            if (-not $change.HasSucceeded) { throw 'Domain unjoin was not successful.' }
        }
        # A reboot is unnecessary: this VM will be shut down and permanently removed.
        [pscustomobject]@{ Verified = $true }
    } -ErrorAction Stop
    if (@($result).Count -ne 1 -or $result.Verified -ne $true) { throw "Unjoin was not confirmed for '$($Node.VM.Name)'." }
}

function Get-LabCleanupHostVMs {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script as Administrator on the Hyper-V host.'
    }
    Import-Module Hyper-V -ErrorAction Stop
    Get-VM -ErrorAction Stop
}

function Assert-LabCleanupVMIdentity {
    param([object[]]$Nodes, [object[]]$AllVMs)

    foreach ($node in $Nodes) {
        $current = @($AllVMs | Where-Object { $_.Id -eq $node.VM.Id -and $_.Name -ieq $node.VM.Name })
        if ($current.Count -ne 1) {
            throw "VM '$($node.VM.Name)' was removed, renamed or replaced since discovery."
        }
    }
}

function Invoke-HyperVLabNodeCleanup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [string[]]$NodeName, [string]$VMRoot = 'D:\HyperV', [string]$DomainControllerVMName,
        [string[]]$ProtectedVMName = @('MylabAD01'),
        [ValidateSet('Standard', 'VMOnly', 'Recovery')][string]$CleanupMode,
        [ValidatePattern('^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$')][string]$DomainName,
        [switch]$AllowComputerSubtreeRemoval,
        [PSCredential]$NodeCredential,
        [PSCredential]$DomainCredential, [int]$ClusterTimeoutSeconds = 600
    )

    $ErrorActionPreference = 'Stop'
    $allVMs = @(Get-LabCleanupHostVMs)
    if (-not $NodeName) { $NodeName = @(Read-Host 'Exact VM names to delete (comma-separated)') }
    $names = @(ConvertTo-LabCleanupNames $NodeName)
    if (-not $CleanupMode) {
        Write-Host '1: Guest-aware cleanup (detect domain/workgroup, clean cluster and AD/DNS when applicable)'
        Write-Host '2: VM-only cleanup (skip ALL guest/cluster/AD/DNS discovery, for OOBE or unfinished builds)'
        Write-Host '3: Recover interrupted cleanup (already-unjoined, powered-off nodes; finish AD/DNS and VM deletion)'
        while (-not $CleanupMode) {
            switch (Read-Host 'Cleanup mode [1]') {
                '' { $CleanupMode = 'Standard' }
                '1' { $CleanupMode = 'Standard' }
                '2' { $CleanupMode = 'VMOnly' }
                '3' { $CleanupMode = 'Recovery' }
                default { Write-Warning 'Select 1, 2 or 3.' }
            }
        }
    }
    $selected = @(
        foreach ($name in $names) {
            if ($ProtectedVMName -icontains $name -or ($DomainControllerVMName -and $DomainControllerVMName -ieq $name)) {
                throw "Protected/DC VM '$name' cannot be selected."
            }
            $match = @($allVMs | Where-Object Name -IEQ $name)
            if ($match.Count -ne 1) {
                throw "Exactly one VM named '$name' is required."
            }
            if ($CleanupMode -eq 'Standard' -and [string]$match[0].State -ne 'Running') {
                throw "VM '$name' must be running for guest-aware cleanup. Use Recovery after interrupted domain cleanup, or VM-only for disposable OOBE leftovers without AD/DNS cleanup."
            }
            if ($CleanupMode -eq 'Recovery' -and [string]$match[0].State -ne 'Off') {
                throw "Recovery requires VM '$name' to be powered off after a previously successful unjoin."
            }
            $match[0]
        }
    )
    $storage = @(Get-LabCleanupStorage -SelectedVMs $selected -AllVMs $allVMs -Root $VMRoot)
    $nodes = @($selected | ForEach-Object { [pscustomobject]@{ VM = $_; Guest = $null } })
    $domain = ''
    $clusters = @()
    $directory = $null
    $dc = @()
    $targets = @()
    if ($CleanupMode -eq 'Standard') {
        if (-not $NodeCredential) { $NodeCredential = Get-Credential -Message 'Local Administrator credential valid on all selected nodes (PowerShell Direct)' }
        if (-not $NodeCredential) { throw 'Node credential entry was cancelled.' }
        $nodes = @(
            foreach ($vm in $selected) {
                $guest = Invoke-Command -VMId $vm.Id -Credential $NodeCredential -ScriptBlock $script:LabCleanupGuestDiscovery -ErrorAction Stop
                if (-not $guest.ComputerName -or -not $guest.Domain) { throw "Guest discovery was incomplete for '$($vm.Name)'." }
                if ($ProtectedVMName -icontains $guest.ComputerName) { throw "Protected guest '$($guest.ComputerName)' cannot be selected." }
                [pscustomobject]@{ VM = $vm; Guest = $guest }
            }
        )
        $domains = @($nodes | Where-Object { $_.Guest.PartOfDomain } | ForEach-Object { $_.Guest.Domain } | Sort-Object -Unique)
        if ($domains.Count -gt 1) { throw 'Select members of at most one AD domain per run.' }
        if (@($nodes | Group-Object -Property { $_.Guest.ComputerName } | Where-Object Count -GT 1).Count -gt 0) {
            throw 'Multiple VMs report the same guest computer name. Cleanup is blocked.'
        }
        $clusters = @(Get-LabCleanupClusters -Nodes $nodes)
        if ($domains.Count -eq 1) {
            $domain = $domains[0]
            if ($domain -notmatch '^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$') { throw 'Invalid discovered AD DNS domain.' }
            $targets = @(Get-LabCleanupTargets -Nodes @($nodes | Where-Object { $_.Guest.PartOfDomain }) `
                -Clusters @($clusters | Where-Object DomainJoined) -Domain $domain)
            if (@($targets | Group-Object Fqdn | Where-Object Count -GT 1).Count -gt 0) {
                throw 'Duplicate node/cluster identities were discovered; cleanup requires manual inspection.'
            }
        }
    }
    if ($CleanupMode -eq 'Recovery') {
        while ([string]::IsNullOrWhiteSpace($DomainName)) {
            $answer = Read-Host 'Original AD DNS domain for these already-unjoined nodes [mylab.local]'
            if ([string]::IsNullOrWhiteSpace($answer)) { $answer = 'mylab.local' }
            if ($answer.Trim() -match '^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$') {
                $DomainName = $answer.Trim()
            }
            else { Write-Warning 'Enter a valid AD DNS domain, for example mylab.local.' }
        }
        $domain = $DomainName
        $targets = @(
            foreach ($name in $names) {
                [pscustomobject]@{ Name = $name; Fqdn = "$name.$domain"; Kind = 'Recovery'; ObjectGUID = '' }
            }
        )
    }
    if ($domain) {
        if (-not $DomainControllerVMName) {
            $defaultDC = 'MylabAD01'
            if ($CleanupMode -ne 'Recovery') {
                $dnsAddresses = @($nodes | Where-Object { $_.Guest.PartOfDomain } | ForEach-Object { $_.Guest.PrimaryDns } | Sort-Object -Unique)
                $candidates = @(
                    foreach ($vm in $allVMs) {
                        $ips = @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop | Select-Object -ExpandProperty IPAddresses)
                        if (@($ips | Where-Object { $dnsAddresses -contains $_ }).Count -gt 0) { $vm.Name }
                    }
                )
                $defaultDC = if ($candidates.Count -eq 1) { $candidates[0] } else { 'MylabAD01' }
                Write-Host "Domain: $domain; primary DNS: $($dnsAddresses -join ', ')"
                Write-Host "DNS-discovered DCs: $(($nodes.Guest.DomainControllerHosts | Sort-Object -Unique) -join ', ')"
            }
            $answer = Read-Host "Domain controller VM for PowerShell Direct [$defaultDC]"
            $DomainControllerVMName = if ([string]::IsNullOrWhiteSpace($answer)) { $defaultDC } else { $answer.Trim() }
        }
        $dc = @($allVMs | Where-Object Name -IEQ $DomainControllerVMName)
        if ($dc.Count -ne 1 -or [string]$dc[0].State -ne 'Running' -or $names -icontains $dc[0].Name) {
            throw 'The DC must be a separate, running, exact-name local Hyper-V VM.'
        }
        if (-not $DomainCredential) { $DomainCredential = Get-Credential -Message "Domain credential authorized for the planned AD/DNS and any guest/cluster cleanup in $domain" }
        if (-not $DomainCredential) { throw 'Domain credential entry was cancelled.' }
        $directory = Invoke-Command -VMId $dc[0].Id -Credential $DomainCredential -ScriptBlock $script:LabCleanupDirectory `
            -ArgumentList 'Discover', $domain, $targets, @() -ErrorAction Stop
        if (-not $directory.DCName) { throw 'Domain controller discovery did not return a verified identity.' }
        if (@($targets | Where-Object Name -IEQ $directory.DCName).Count -gt 0) { throw 'A cleanup target is the domain controller.' }
    }

    Write-Host "`nPERMANENT cleanup plan (mode: $CleanupMode):"
    if ($domain) { Write-Host "AD domain: '$domain'; DC VM: '$DomainControllerVMName'." }
    elseif ($CleanupMode -eq 'Standard') { Write-Host 'All selected guests are workgroup members. No DC discovery, AD/DNS lookup or domain credential is needed.' }
    $storage | Select-Object VMName, Folder | Format-Table -AutoSize | Out-Host
    $clusters | Select-Object Name, Action, @{Name = 'SelectedMembers'; Expression = { $_.SelectedMembers -join ', ' }} |
        Format-Table -AutoSize | Out-Host
    $directory.Computers | Select-Object Name, Fqdn, ObjectGUID, State,
        @{Name = 'ChildCount'; Expression = { @($_.Children).Count }} | Format-Table -AutoSize | Out-Host
    $childObjects = @($directory.Computers | ForEach-Object { $_.Children } | Where-Object { $null -ne $_ })
    if ($childObjects.Count -gt 0) {
        Write-Host 'AD child objects beneath the selected computer accounts (also permanently deleted if approved):'
        $childObjects | Format-Table ObjectClass, DistinguishedName, ObjectGUID -AutoSize -Wrap | Out-Host
        Write-Warning 'Computer-subtree deletion can remove recovery information and service-registration objects. Preserve any information you still need before approving.'
    }
    $directory.DnsRecords | Format-Table Zone, Owner, Type -AutoSize | Out-Host
    if ($CleanupMode -eq 'VMOnly') {
        Write-Warning 'VM-only mode can abruptly power off VMs. It does NOT detect DCs or clean AD, DNS or clusters. It can leave orphan objects or damage a live cluster. Use only for known disposable/OOBE VMs.'
    }
    if ($CleanupMode -eq 'Recovery') {
        Write-Warning 'Recovery assumes VM names exactly match their original Windows/AD computer names and unjoin already succeeded. It does not log in to guests, repeat unjoin, discover clusters, or remove shared cluster identities. Existing AD accounts must be disabled.'
    }
    Write-Warning 'This deletes the selected VMs and all contents of their dedicated folders, plus any guest/cluster/AD/DNS actions listed above. There is no undo.'
    Write-Host 'Partial-cluster CNO/VCO objects, AD OUs, host switches, NAT and external parent templates are preserved.'
    if (-not $PSCmdlet.ShouldProcess(($names -join ', '), 'Unjoin nodes and permanently delete their AD/DNS identities, VMs and storage')) { return }
    $verb = if ($CleanupMode -eq 'Recovery') { 'RECOVER' } else { 'DELETE' }
    $phrase = "$verb $($names -join ',')"
    if ((Read-Host "Type exactly '$phrase' to proceed") -cne $phrase) {
        Write-Host 'Cancelled. No changes were made.'
        return
    }
    if ($childObjects.Count -gt 0 -and -not $AllowComputerSubtreeRemoval) {
        if ((Read-Host "Type exactly 'DELETE AD CHILD OBJECTS' to approve only the displayed computer subtrees") -cne 'DELETE AD CHILD OBJECTS') {
            Write-Host 'Cancelled. No changes were made.'
            return
        }
        $AllowComputerSubtreeRemoval = $true
    }

    $stage = 'revalidating VM identities and storage'
    try {
        $allVMs = @(Get-VM -ErrorAction Stop)
        Assert-LabCleanupVMIdentity -Nodes $nodes -AllVMs $allVMs
        if ($CleanupMode -eq 'Recovery' -and @($allVMs | Where-Object {
            $selected.Id -contains $_.Id -and [string]$_.State -ne 'Off'
        }).Count -gt 0) {
            throw 'A recovery VM is no longer powered off. No directory cleanup will be attempted.'
        }
        [void](Get-LabCleanupStorage -SelectedVMs @($allVMs | Where-Object { $selected.Id -contains $_.Id }) -AllVMs $allVMs -Root $VMRoot)
        foreach ($cluster in $clusters) {
            $stage = "$($cluster.Action) cluster '$($cluster.Name)'"
            $clusterCredential = if ($cluster.DomainJoined) { $DomainCredential } else { $NodeCredential }
            Invoke-LabCleanupCluster -Plan $cluster -NodeCredential $NodeCredential -DomainCredential $clusterCredential -TimeoutSeconds $ClusterTimeoutSeconds
        }
        foreach ($node in $nodes) {
            if ($CleanupMode -eq 'Recovery') { continue }
            if ($CleanupMode -eq 'Standard' -and $node.Guest.PartOfDomain) {
                $stage = "unjoining '$($node.VM.Name)'"
                Invoke-LabCleanupUnjoin -Node $node -NodeCredential $NodeCredential -DomainCredential $DomainCredential
            }
            $stage = "shutting down '$($node.VM.Name)'"
            if ($CleanupMode -eq 'VMOnly') {
                if ([string]$node.VM.State -ne 'Off') {
                    Stop-VM -VM $node.VM -TurnOff -Force -Confirm:$false -ErrorAction Stop
                }
            }
            else {
                Stop-VM -VM $node.VM -Force -Confirm:$false -ErrorAction Stop
            }
            $current = @(Get-VM -ErrorAction Stop | Where-Object Id -EQ $node.VM.Id)
            if ($current.Count -ne 1 -or [string]$current[0].State -ne 'Off') { throw 'VM did not reach the Off state.' }
        }
        if ($domain) {
            $stage = 'removing and verifying AD/DNS objects on the DC'
            $removed = Invoke-Command -VMId $dc[0].Id -Credential $DomainCredential -ScriptBlock $script:LabCleanupDirectory `
                -ArgumentList 'Remove', $domain, $targets, @($directory.Computers), ([bool]$AllowComputerSubtreeRemoval) -ErrorAction Stop
            if (@($removed).Count -ne 1 -or $removed.Verified -ne $true) { throw 'Directory cleanup did not return verified completion.' }
        }
        foreach ($plan in $storage) {
            $stage = "deleting VM '$($plan.VMName)' and its dedicated storage"
            $allVMs = @(Get-VM -ErrorAction Stop)
            Assert-LabCleanupVMIdentity -Nodes @($nodes | Where-Object { $_.VM.Id -eq $plan.VMId }) -AllVMs $allVMs
            $vm = @($allVMs | Where-Object Id -EQ $plan.VMId)
            if ($vm.Count -ne 1 -or [string]$vm[0].State -ne 'Off') { throw 'VM identity/state changed before deletion.' }
            [void](Get-LabCleanupStorage -SelectedVMs @($vm[0]) -AllVMs $allVMs -Root $VMRoot)
            Remove-VM -VM $vm[0] -Force -Confirm:$false -ErrorAction Stop
            $remaining = @(Get-VM -ErrorAction Stop)
            if (@($remaining | Where-Object Id -EQ $plan.VMId).Count -gt 0) { throw 'VM is still registered after removal.' }
            Assert-LabCleanupFolder -Folder $plan.Folder -Root $VMRoot -Name $plan.VMName
            # Recheck surviving VM references after unregistering, before removing any files.
            Assert-LabCleanupStorageReferences -Plans @($plan) -AllVMs $remaining
            Remove-Item -LiteralPath $plan.Folder -Recurse -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $plan.Folder) { throw 'VM folder still exists after deletion.' }
            Write-Host "Removed and verified '$($plan.VMName)' and '$($plan.Folder)'."
        }
    }
    catch {
        throw "Cleanup stopped while $stage. $($_.Exception.Message) Earlier operations may already be permanent. Remaining VMs/files were not automatically deleted; inspect Hyper-V, cluster, AD and DNS state before retrying."
    }
    Write-Host "Cleanup completed and verified for $($names -join ', ')."
}

if ($MyInvocation.InvocationName -ne '.') {
    $PSBoundParameters['VMRoot'] = $VMRoot
    $PSBoundParameters['ProtectedVMName'] = $ProtectedVMName
    $PSBoundParameters['ClusterTimeoutSeconds'] = $ClusterTimeoutSeconds
    Invoke-HyperVLabNodeCleanup @PSBoundParameters
}
