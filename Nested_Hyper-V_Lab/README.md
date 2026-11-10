# Nested Hyper-V Lab Preparation for Failover Clustering and S2D

Prepare domain-joined Windows Server VMs with nested virtualization enabled as
the foundation for a Hyper-V, Failover Clustering, and Storage Spaces Direct
(S2D) lab. The scripts provision the lab nodes, configure the guests through
PowerShell Direct, and clean up disposable nodes through one menu.

Installing Hyper-V inside the guest nodes, creating a failover cluster, and
enabling S2D are subsequent steps; this package does not automate them.

**Prepare an unattended parent image first.** This avoids completing Windows
OOBE separately on every new VM and lets the configured deployment continue
without per-node console interaction. Preparing the reference image, entering
credentials, choosing resources, and confirming the deployment remain
interactive; this is not a completely non-interactive installer.

> **Lab use only:** guest configuration disables all Windows Firewall profiles
> and IPv6 bindings, and enables nested-virtualization settings. Cleanup can
> permanently remove selected VMs, disks, and matching directory/DNS objects.
> Review the defaults and safeguards before running anything.

## Automation boundary and next steps

The package automates the preparation phase:

- Generation 2 VM creation, resource selection, nested-virtualization exposure,
  and optional blank data disks.
- Unattended first boot from a prepared parent, guest networking, time zone,
  domain join, name/OU verification, and eligible AVMA activation.
- Explicit recovery and guarded cleanup of disposable lab nodes.

After provisioning succeeds, you still need to:

1. Install the Hyper-V and Failover Clustering roles/features inside the
   intended guest nodes.
2. Verify Windows Server edition/licensing, resource sizing, networking, and
   storage requirements for your intended S2D lab.
3. Run cluster validation, create the failover cluster, and configure quorum.
4. Enable S2D and create the required storage volumes and clustered workloads.

Select suitable data-disk counts and capacities during provisioning; the
default is no additional data disks. **Leave disks intended for S2D pooling
empty, unpartitioned, and unformatted.** Do not prepare them as ordinary
standalone data volumes first. Provisioning success does not certify that all
clustering or S2D prerequisites have been met. Follow Microsoft's
[Storage Spaces Direct deployment guide](https://learn.microsoft.com/en-us/windows-server/storage/storage-spaces/deploy-storage-spaces-direct)
for those later steps.

## Files and where to run them

| File | Run on | Purpose |
|---|---|---|
| [Manage-HyperVLab.ps1](./Manage-HyperVLab.ps1) | Hyper-V host | Recommended entry point: create/configure or clean up lab nodes. |
| [New-HyperVLab-Configured.ps1](./New-HyperVLab-Configured.ps1) | Hyper-V host | Self-contained provisioning, guest configuration, domain join, eligible AVMA activation, and explicit resume mode. |
| [Prepare-HyperVLabTemplate.ps1](./Prepare-HyperVLabTemplate.ps1) | Inside a standalone reference VM | Create and validate the unattended answer file; does not execute Sysprep. |
| [Remove-HyperVLabNodes.ps1](./Remove-HyperVLabNodes.ps1) | Hyper-V host | Cleanup engine used by menu option 2. |
| [Prepare-HyperVLabTemplate.README.md](./Prepare-HyperVLabTemplate.README.md) | Documentation | Detailed reference-image preparation, Sysprep, validation, and troubleshooting. |
| [How to use.txt](./How%20to%20use.txt) | Documentation | Short operational checklist. |

Keep the menu, configured provisioner, and cleanup engine together on the host.
The configured provisioner does not require another provisioning script.

## Recommended unattended deployment workflow

### 1. Download and review

Clone the repository, or download its ZIP and open the `Nested_Hyper-V_Lab` folder:

```powershell
git clone https://github.com/VishalDesai85/AutomationandScripting.git
Set-Location .\AutomationandScripting\Nested_Hyper-V_Lab
```

Use **Windows PowerShell 5.1 as Administrator** on the Hyper-V host. Hyper-V
and its PowerShell module must already be installed. The target virtual
switches and the domain-controller VM must already exist; the scripts do not
create the AD domain or configure host NAT.

If downloaded files are blocked, review the scripts before unblocking them:

```powershell
Get-ChildItem -LiteralPath . -Filter '*.ps1' -File | Unblock-File
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
```

The execution-policy change applies only to that PowerShell process and does
not override organizational policy.

### 2. Prepare the parent once, inside the reference VM

Create a standalone Generation 2 reference VM, install/update Windows, and
leave it in a workgroup. Copy the preparation helper into that VM and run it
from an elevated Windows PowerShell window:

```powershell
Set-Location C:\HyperVLab
.\Prepare-HyperVLabTemplate.ps1
```

`C:\HyperVLab` is an example working directory inside the reference VM; it does
not need to match the repository folder name.

Enter a lab-specific local Administrator password. Review the generated
`C:\HyperVLab\Unattend.xml`, then run the Sysprep command printed by the helper.
The helper **does not run Sysprep for you**.

Wait for Sysprep to shut down the reference VM. Publish its standalone VHDX as
the parent image, do not boot that parent again, and validate one disposable
child before deploying a batch. Follow the
[complete template guide](./Prepare-HyperVLabTemplate.README.md) for all steps.

**Never modify a parent VHDX after differencing children depend on it.**
Answer-file passwords are encoded, not encrypted. Never commit generated
answer files, credentials, Windows installation media, or virtual disks.

### 3. Preview and deploy from the Hyper-V host

From the folder containing the host scripts, preview the create workflow:

```powershell
.\Manage-HyperVLab.ps1 -WhatIf
```

Choose **1** for the creation preview. Then run the menu without `-WhatIf`:

```powershell
.\Manage-HyperVLab.ps1
```

Choose **1** to create and configure nodes. Supply the template's local
Administrator credential and a separate AD credential permitted to create
the deployment OU and join computers. Select the prepared parent VHDX,
resource settings, disks, and switches; review and confirm the plan.

The configured workflow starts the new VMs, waits for unattended first boot,
configures guest networking and time zone, renames/restarts each guest before
domain join, verifies the final domain/OU placement, and activates eligible
Windows Server guests using AVMA.

### 4. Use direct invocation for advanced settings or recovery

Run the configured script directly to override the domain/network defaults:

```powershell
.\New-HyperVLab-Configured.ps1 `
    -VMRoot 'E:\HyperV' `
    -NamePrefix 'LABVM' `
    -DomainName 'lab.example' `
    -DomainControllerVMName 'LABDC01' `
    -SubnetPrefix '192.168.50' `
    -Gateway '192.168.50.1' `
    -DnsServer '192.168.50.10' `
    -GuestTimeZone 'UTC'
```

These are example values: the DC, AD domain, writable OU location, DNS, virtual
switches, and routing must match your environment. The configured network
workflow currently supports `/24` subnets. The menu exposes storage-root and
DC-VM overrides; use the configured script for other parameters.

For an interrupted run, use `-ConfigureExistingVMName` and the existing OU as
described in the [recovery instructions](#when-powershell-direct-reports-the-credential-is-invalid).
Do not use the create menu to resume: it allocates another batch.

## Default lab configuration

Review these defaults before using the menu:

| Setting | Default |
|---|---|
| VM storage root | `D:\HyperV` |
| Parent-image prompt example/default | `D:\Differencing\Template2025.vhdx` |
| VM naming prefix | `HypNode` |
| AD DNS domain | `mylab.local` |
| Existing DC VM on the same host | `MylabAD01` |
| Management subnet | `10.151.33.0/24` |
| Gateway | `10.151.33.1` |
| DNS/DC IPv4 address | `10.151.33.84` |
| Management / SMB virtual switches | `Natswitch` / `SMB-Network` |
| Guest time zone | `India Standard Time` |

The DNS/DC address and virtual switches must be reachable and appropriate for
the selected guest network. AVMA is optional and requires an eligible,
activated Datacenter host; it is not a replacement for Windows licensing.

## Single create/cleanup menu

Run **`Manage-HyperVLab.ps1` as Administrator on the Hyper-V host**:

```powershell
.\Manage-HyperVLab.ps1
```

```text
1: Create and configure Hyper-V lab nodes
2: Clean up Hyper-V lab nodes
```

Option 1 runs the existing `New-HyperVLab-Configured.ps1` workflow below.
Option 2 runs `Remove-HyperVLabNodes.ps1`. Keep all three scripts in the same
folder when copying them to the host. There is one user-facing entry point;
the build and destructive cleanup engines remain separate so that neither
duplicates nor changes the existing provisioning implementation.

```powershell
.\Manage-HyperVLab.ps1 -WhatIf
.\Manage-HyperVLab.ps1 -VMRoot 'E:\HyperV' -DomainControllerVMName 'MylabAD01'
```

`-WhatIf` is forwarded to the chosen workflow. Cleanup preview requires
credentials and performs read-only guest/DC discovery in guest-aware mode;
VM-only preview does not contact any guest.

### Deployment naming

Creation now prompts for a **VM naming prefix**. Enter `MSLABVM` to create
`MSLABVM01`, `MSLABVM02`, and so on. Press Enter to use `HypNode`, which produces
`HypNode01`, `HypNode02`, etc. Guest Windows computer names and VM folders match
the generated VM names.

The configured creation workflow derives a root-level AD OU family from that
prefix: replace a trailing `VM` with `OU` (case-insensitive), otherwise append
`OU`. Thus `MSLABVM` uses `MSLABOU`, while `TestNode` uses `TestNodeOU`.
Each deployment gets the first unused OU in its family: `MSLABOU`,
`MSLABOU01`, `MSLABOU02`, etc. Assuming prior VMs and OUs still exist:

| Deployment | Prefix | Count | VM names | AD OU |
|---|---|---|---|---|
| First | `MSLABVM` | 4 | `MSLABVM01` through `MSLABVM04` | `MSLABOU` |
| Next | `MSLABVM` | 4 | `MSLABVM05` through `MSLABVM08` | `MSLABOU01` |

VM allocation checks existing VM names and folders case-insensitively and uses
the first free numbers, not necessarily the highest number plus one. Existing
unpadded names/folders such as `MSLABVM1` also reserve that number. OU allocation
similarly reserves legacy names such as `MSLABOU1` when considering `MSLABOU01`.
Name allocation never renames existing Hyper-V VMs or OUs. Explicit resume
mode can rename a selected guest's Windows computer to finish an interrupted
deployment. New numeric suffixes have a minimum width of two; after 99 they
continue as 100, 101, etc.

Prefixes must start with a letter, contain only letters/digits/hyphens, and
be at most 13 characters. Every complete VM name is checked against Windows'
15-character computer-name limit before any VMs are created; use a shorter
prefix if allocating three or more suffix digits would exceed that limit.

For direct invocation, `-NamePrefix 'MSLABVM'` skips the naming prompt.
`-OUBaseName 'CustomOU'` overrides automatic OU derivation in the configured
script; `-ExistingOUName 'MSLABOU'` still reuses an explicitly selected OU.
When resuming existing VMs without `-ExistingOUName` or `-OUBaseName`, supply or
enter their original family prefix to derive the correct OU family. WhatIf
shows the derived OU base without contacting AD; the actual available OU suffix
is allocated on the DC during execution.

### Cleanup modes

Cleanup asks for **exact VM names**, separated by commas, spaces or semicolons.
Wildcards and ranges are rejected. It then offers:

1. **Guest-aware cleanup** (default): requires running guests and a local
   Administrator credential valid on all selected nodes. PowerShell Direct
   discovers the guest computer name, AD/workgroup membership, primary IPv4
   DNS server and cluster membership.
   - Workgroup-only selections do not discover/contact a DC, request domain
     credentials, unjoin a domain, or perform AD/DNS cleanup.
   - Domain members resolve DC SRV records using their primary DNS. The script
     suggests a DC VM from Hyper-V-reported DNS IP addresses, or `MylabAD01`
     when no unique match exists. Confirm/enter the DC VM name, or pass
     `-DomainControllerVMName`. The DC must be running on the same host and
     host that domain and a writable DNS zone for it.
   - A batch may contain workgroup VMs and members of **one** AD domain.
     Only domain members' identities are sent to the DC.
2. **VM-only cleanup**: for OOBE, failed builds or disposable offline VMs.
   It does not connect to guests or discover/modify domains, DNS or clusters,
   and does not request credentials. Running VMs can be **abruptly powered
   off**. Existing AD/DNS/cluster objects remain and require separate cleanup.
   DC-role detection is impossible in this mode: use it only when you already
   know the selected VMs are disposable lab nodes.
3. **Recovery**: finish an interrupted cleanup after domain unjoin succeeded
   and the nodes were powered off, but AD/DNS or VM deletion failed. It requires
   all selected VMs to be **Off**, an explicitly supplied/confirmed original AD
   DNS domain, and a running DC VM. It does not contact the selected guests,
   request their local credentials, repeat unjoin, or rediscover/evict clusters.
   VM names must exactly match their original Windows/AD computer names.
   Remaining AD computer accounts must be **disabled**; enabled accounts block
   recovery because they might still be active domain members. Already-absent
   AD accounts and matching DNS records are accepted as completed work.

All modes retain exact-name, protected-VM and host-storage safety checks.
`MylabAD01` and an explicitly specified DC VM are protected. Guest-aware mode
also rejects **any actual AD domain controller**, regardless of its VM name.
"Demotion" here means `Remove-Computer` to unjoin a **member server**, not
AD DS domain-controller demotion.

### Guest-aware cleanup order and safeguards

1. Discover and preview all selected VMs, folders, cluster actions, AD account
   GUIDs, their child-object inventory, and matching DNS records before changing anything.
2. Require PowerShell confirmation plus a typed phrase such as
   `DELETE HypNode01,HypNode02`. `-Confirm:$false` skips only PowerShell's prompt,
   **not** this typed confirmation.
   If a computer account has children, also require `DELETE AD CHILD OBJECTS`
   before any guest/cluster/AD/VM changes. This additional prompt may be
   explicitly pre-authorized with `-AllowComputerSubtreeRemoval`; the main typed
   confirmation is still required. WhatIf never requests deletion confirmation.
3. If only some cluster members are selected, drain/evict those nodes and
   preserve the cluster's shared CNO/VCO computer accounts and DNS identities.
   If **every** member is selected, destroy the cluster and include its
   discovered network-name identities in AD/DNS cleanup. AD deletion requires
   matching resource `ObjectGUID`s; it never guesses objects by a name prefix.
   Partial Storage Spaces Direct removal is blocked for manual storage
   retirement. Eviction is blocked while cluster groups still belong to a
   selected node.
4. Unjoin domain members using securely entered domain credentials, require
   `HasSucceeded`, then shut down the selected VMs. There is no unjoin reboot
   because the VM will be permanently deleted. Workgroup members skip unjoin.
5. Through PowerShell Direct to the DC, remove exact computer accounts by GUID
   and verify absence. Leaf accounts use `Remove-ADComputer`; accounts with
   approved child objects use `Remove-ADObject -Recursive` against **only that
   verified computer's GUID**, never an OU/domain. The inventory includes class,
   DN and GUID only, not child attribute values such as recovery passwords.
   Protected accounts/descendants, unknown protection status, separate
   computer/user/group/OU/domain objects below a computer, replacement accounts,
   moved accounts and new/changed descendants since preview block deletion.
   Protection flags are never automatically disabled. Back up any recovery
   information you need before approving subtree deletion.
   Clean exact DNS owners and PTR/CNAME/SRV destinations
   matching the selected FQDNs in that DC's writable, non-autocreated zones.
   Similar names and records that merely share an IP are preserved. NS/SOA
   dependencies block cleanup for manual review. External DNS servers,
   secondary zones, caches, DHCP leases and unrelated records are not modified.
6. Revalidate VM IDs, disk chains and storage ownership, unregister each
   selected VM, then delete its entire dedicated `<VMRoot>\<VMName>` folder.
   Verify that the VM registration and folder are gone before reporting success.

Storage deletion is deliberately limited to the provisioner's dedicated folder
layout. External disks/configuration, pass-through/shared disks, reparse points,
drive roots, host/workspace paths and folders referenced by another VM or its
checkpoint/backing chain block cleanup rather than risk data loss. External
parent templates, AD OUs, virtual switches and host NAT configuration are kept.
Nested guest data inside the deleted disks is **permanently lost**.

Cluster mutations run in a fresh credentialed local PowerShell job inside the
guest, avoiding the cluster cmdlets' remoting credential-delegation restriction.
Domain credentials need local guest administration, cluster administration,
domain-unjoin, computer-account deletion and DNS-record deletion permissions.
For workgroup clusters the node credential is used instead. No passwords are
written into scripts or files.
Do not concurrently reconfigure VMs, their storage, cluster membership or target AD/DNS objects during
cleanup; the script revalidates ownership but cannot make these systems one
atomic transaction.

On any failure the script stops and names the failed stage; it does not pretend
the batch succeeded or delete the remaining VMs as a fallback. Earlier cluster,
domain or deletion operations may already be permanent. Inspect partial results
before retrying. If a VM is already unjoined, guest-aware mode treats it as a
workgroup server and cannot infer its former AD/DNS identity.

### Recovering the non-leaf AD account failure

`The directory service can perform the requested operation only on a leaf object`
means a computer account has child objects, such as service registrations or
BitLocker recovery objects; it does not identify their exact classes. Older
cleanup versions attempted `Remove-ADComputer` without handling those children.
Unjoin and shutdown may already have succeeded, while AD accounts remain.
The DNS table displayed before confirmation is a **preview**, not proof that
those records were removed.

Copy the updated `Remove-HyperVLabNodes.ps1` from this folder to
`C:\scripts\Remove-HyperVLabNodes.ps1` on the Hyper-V host. Leave the already-unjoined
VMs off. In **Administrator PowerShell**, run this complete, single-line recovery
preview command (adjust the script path if you use a different folder):

```powershell
& 'C:\scripts\Remove-HyperVLabNodes.ps1' -NodeName 'HypNode1','HypNode2','HypNode3','HypNode4' -CleanupMode Recovery -DomainName 'mylab.local' -DomainControllerVMName 'MylabAD01' -WhatIf
```

The absolute path works regardless of the current directory. In PowerShell ISE,
select the **entire command** before pressing **F8**. Selecting only a parameter
line such as `-DomainName ...` runs it as a separate command and produces
`The term '-DomainName' is not recognized`. These single-line examples avoid
backtick continuation and partial-selection problems.

Check the exact AD accounts, child objects, any remaining DNS entries and VM
folders, then run the same command **without `-WhatIf`**:

```powershell
& 'C:\scripts\Remove-HyperVLabNodes.ps1' -NodeName 'HypNode1','HypNode2','HypNode3','HypNode4' -CleanupMode Recovery -DomainName 'mylab.local' -DomainControllerVMName 'MylabAD01'
```

Enter the domain credential, type the displayed `RECOVER ...` phrase, and
approve `DELETE AD CHILD OBJECTS` if applicable. Recovery verifies remaining
AD/DNS cleanup before deleting VMs/files. It preserves AD OUs, shared cluster
identities and external parent templates. For a cluster, confirm the prior
cluster teardown/eviction step already completed; recovery cannot reconstruct
cluster membership from powered-off guests and does not guess CNO/VCO objects.
If VM names and original guest computer names differ, do not use recovery's
name-based target mapping: inspect and clean the exact directory objects manually.

The cleanup engine can also be run directly:

```powershell
.\Remove-HyperVLabNodes.ps1 -NodeName HypNode01,HypNode02 -CleanupMode Standard -WhatIf
.\Remove-HyperVLabNodes.ps1 -NodeName HypNode01,HypNode02 -DomainControllerVMName MylabAD01
.\Remove-HyperVLabNodes.ps1 -NodeName HypNode03 -CleanupMode VMOnly -WhatIf
```

## VM creation settings

The configured provisioner embeds its VM creation engine; no separate base
script is needed. Run it **as Administrator on the Hyper-V host**, either
through menu option 1 or directly:

```powershell
.\New-HyperVLab-Configured.ps1
```

Normal creation allocates new VM names and does not overwrite existing VMs.
Only explicit `-ConfigureExistingVMName` mode configures selected existing
guests.

## Prompts and defaults

- VM naming prefix: **HypNode**, producing `HypNode01`, `HypNode02`, etc.
- VM count: **4**.
- Parent OS VHDX prompt: `Parent OS VHDX path [example D:\Differencing\Template2025.vhdx]:`.
  Press Enter to use **D:\Differencing\Template2025.vhdx**, or enter another path
  to choose another image. Paths with spaces and surrounding double quotes work.
- Compute: assign the same RAM and vCPU count to every VM, or configure each
  individually. RAM can be fixed or dynamic. For Dynamic Memory, the entered
  capacity is the maximum ceiling, the minimum is **512MB**, and startup RAM is
  requested separately. RAM entries accept sizes such as `8GB`, `1.5GB`, or
  `0.5TB`. vCPU count defaults to 4 (or the host's logical processor count if
  lower) and must not exceed it.
- Extra data disks: none, the same disk configuration for every VM, or a separate
  configuration per VM. After specifying the disk count, choose one capacity for
  every dynamic data disk or configure each disk's capacity individually.
  Capacities accept GB or TB, including decimals, from 1GB through 64TB.
- NAT adapters per VM: **2**, attached to **Natswitch** by default.
- SMB adapters per VM: **2**, attached to **SMB-Network** by default.
  Select the existing switch for each group from a numbered list. Counts may be
  zero, with at most eight adapters total per VM for compatibility.
  The same network configuration is applied to all new VMs.
- MAC address spoofing: **enabled** by default for bridged nested-VM traffic.
  Select No if you will use guest NAT instead.
- The configured workflow starts new VMs automatically for guest configuration.
- Review the plan and confirm creation: **No** by default.

Only the OS disk is **differencing**, using your selected parent. Additional
data disks are independent **dynamically expanding VHDX** files, not differencing
disks. GB/TB use PowerShell's binary units (GiB/TiB); fractional MiB round upward.

## VM configuration and storage

- Names: `<your prefix>01`, `<your prefix>02`, etc. The first unused suffixes are selected,
  checking existing VM names case-insensitively and existing folders. Reruns
  create new VMs; they do not reuse or overwrite old ones.
- Generation 2, selected fixed or Dynamic Memory, and CPU virtualization
  extensions exposed.
- OS disk on **SCSI controller 0, location 0**, first in firmware boot order.
- Data disks on SCSI controller 0 at locations 1, 2, etc. (up to 63 data disks).
- Host integration-service **time synchronization disabled**.
- Adapters named `NAT1`, `NAT2`, `SMB1`, `SMB2` with the default counts.
  The default adapter created by Hyper-V is removed, so there is no fifth NIC.
  Hyper-V advanced features enable guest NIC teaming participation and device
  naming on every assigned adapter.

Example layout:

```text
D:\HyperV\
  HypNode01\
    Virtual Machines\...
    Virtual Hard Disks\
      HypNode01-OS.vhdx
      HypNode01-Data01.vhdx
      HypNode01-Data02.vhdx
  HypNode02\...
```

Optional storage/name overrides and a non-mutating preview:

```powershell
.\New-HyperVLab-Configured.ps1 -VMRoot 'D:\HyperV' -NamePrefix 'HypNode'
.\New-HyperVLab-Configured.ps1 -WhatIf
```

`-WhatIf` still collects settings and displays the plan, but creates no files,
disks, adapters, or VMs. Declining the final confirmation also creates nothing.
On failure, provisioning stops with an error. Newly created partial resources
are preserved for inspection rather than automatically deleted; reruns skip
their names/folders. If starting fails, some new VMs may already be running.

## Prerequisites and guest setup

- Hyper-V and its PowerShell module must already be installed.
- Use a **generalized, Generation 2 Windows image** prepared with Sysprep, with
  a UEFI/GPT boot layout compatible with Windows Secure Boot. The script cannot
  infer boot compatibility from a VHDX file or convert a Generation 1 image.
- Keep the parent accessible and unchanged for the lifetime of every
  differencing child. A parent already shared by other differencing disks is
  supported, including children attached to running VMs. The script rejects the
  parent only if the template itself is directly attached to a VM or mounted on
  the host, or its VHD backing chain is invalid. It does not modify the parent
  or existing children.
- Intel nested virtualization requires Windows Server 2016 / Windows 10 or
  later and VM version 8.0+. AMD Ryzen/EPYC requires Windows Server 2022 /
  Windows 11 or later and VM version 9.3+. Unsupported configurations fail
  explicitly when Hyper-V applies the settings.
- The selected virtual switches must already exist. Selecting a switch named
  `Natswitch` **does not create or configure NAT**. The script does not change
  host networking, VLANs, IP addresses, DNS, or switch configuration.
- Install the Hyper-V role **inside** each new guest when ready; the script
  exposes virtualization extensions but does not install that guest role.
  The configured workflow handles guest naming, networking, DNS, and domain
  join. Data disks start blank. Leave disks intended for S2D pooling
  unpartitioned and unformatted; only initialize standalone disks that are not
  intended for the S2D pool.
- Disabling host time synchronization does not disable Windows Time inside
  the guest; domain-joined guests can use AD time synchronization.
- Allow enough RAM for the host, `MylabAD01`, and existing VMs. Dynamic and
  differencing disks consume more host storage as data is written; requested
  capacities do not reserve that storage.

References: [nested virtualization prerequisites and networking](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/enable-nested-virtualization),
[New-VHD](https://learn.microsoft.com/en-us/powershell/module/hyper-v/new-vhd).

## Prepare the parent for unattended first boot

PowerShell Direct cannot configure a guest while Windows is stopped at the
interactive **Hi there** OOBE screen. Before running Sysprep, copy
`Prepare-HyperVLabTemplate.ps1` into the reference VM and run it from an
elevated PowerShell window:

See [Prepare-HyperVLabTemplate.README.md](./Prepare-HyperVLabTemplate.README.md)
for the complete reference-image creation, Sysprep, validation, recovery, and
troubleshooting procedure.

```powershell
.\Prepare-HyperVLabTemplate.ps1
```

The helper securely prompts for the built-in Administrator password and creates
`C:\HyperVLab\Unattend.xml`. It configures the `en-IN` locale, India time zone,
OOBE page suppression, the Administrator password, and one automatic
Administrator logon. It validates the XML but deliberately does not launch
Sysprep. Review the answer file, then run the command printed by the helper:

```powershell
& "$env:SystemRoot\System32\Sysprep\Sysprep.exe" /generalize /oobe /mode:vm /shutdown /unattend:"C:\HyperVLab\Unattend.xml"
```

After the reference VM shuts down, use its VHDX as the parent and do not boot it
again. Unattend password values are hidden with Windows answer-file encoding,
not encrypted; protect the answer file and the resulting parent VHDX.

## Configured domain-join variant

`New-HyperVLab-Configured.ps1` is a self-contained end-to-end variant. It embeds
the base provisioning functions and then configures only the newly created VMs
through PowerShell Direct. Copying this one script to the Hyper-V host is enough;
it does not load a neighboring `New-HyperVLab.ps1`:

```powershell
.\New-HyperVLab-Configured.ps1
```

The default post-provisioning workflow:

1. Securely prompts for the template's local `Administrator` credential and an
   AD credential. Passwords are not embedded, documented, or written to disk.
   Enter the credential configured securely in your template.
2. Requires the running `MylabAD01` VM to host `mylab.local`, report
   `10.151.33.84`, and resolve the domain-controller DNS SRV record.
3. Creates and starts the new VMs, then waits up to 15 minutes for PowerShell
   Direct, reporting progress and identifying OOBE as a likely blocker. No
   interactive console login or guest network connectivity is needed when the
   parent was prepared with the supplied unattend helper.
4. Disables and verifies the Domain, Private, and Public Windows Firewall
   profiles immediately after PowerShell Direct becomes available. It verifies
   them again every 15 seconds for two minutes after the domain-join restart,
   re-disabling any profile that turns itself back on. It also sets and verifies
   the guest time zone as `India Standard Time` before configuration and after
   the domain-join restart.
5. Selects addresses from `10.151.33.2` through `10.151.33.254`, excluding the
   `10.151.33.1` gateway, `10.151.33.84` DNS/DC address, Hyper-V-reported guest
   addresses, existing `mylab.local` DNS A records, and addresses detected by
   ping or neighbor discovery from the DC.
6. Maps host adapters to guest adapters by MAC address. Adapters on `Natswitch`
   become `mgmt1`, `mgmt2`, and so on; adapters on `SMB-Network` become `smb1`,
   `smb2`, and so on.
7. Disables IPv6 binding on every guest adapter. Only `mgmt1` receives an IPv4
   configuration: `/24`, gateway `10.151.33.1`, and primary DNS
   `10.151.33.84`. DHCP and existing IPv4 addresses are removed from the other
   guest adapters.
8. Creates the derived OU at the domain root (`MSLABVM` -> `MSLABOU`,
   or default `HypNode` -> `HypNodeOU`). If it exists, the first unused
   serialized name is used (`MSLABOU01`, `MSLABOU02`, and so on).
9. Renames each workgroup guest to its Hyper-V VM name and waits for a verified
   reboot before joining it to `mylab.local` in the new OU. It then waits for a
   second verified reboot and checks its name, domain, and AD OU placement.
   Guests already using the target name need only the domain-join reboot.
10. Detects the guest Windows Server version/edition and uses Automatic Virtual
    Machine Activation (AVMA) when the detected Hyper-V host is eligible.
    Activation runs after the guest's domain-join restart has completed.

### Automatic VM activation (AVMA)

`New-HyperVLab-Configured.ps1` automatically checks the **actual host and guest
OS**, not the parent VHDX filename. It uses OS build numbers, edition IDs and
Windows licensing records to select only a verified, matching AVMA key.
The host must run an **activated, non-evaluation Windows Server Datacenter**
edition with Hyper-V. Windows client hosts, Standard hosts, evaluation hosts,
unlicensed hosts and unrecognized or ambiguous licensing data cannot supply
AVMA activation.

The supported version relationship follows
[Microsoft's AVMA compatibility table and generic keys](https://learn.microsoft.com/en-us/windows-server/get-started/automatic-vm-activation):

| Activated Datacenter host | Guest versions eligible for AVMA |
|---|---|
| Windows Server 2025 | 2025, 2022, 2019, 2016, 2012 R2 |
| Windows Server 2022 | 2022, 2019, 2016, 2012 R2 |
| Windows Server 2019 | 2019, 2016, 2012 R2 |
| Windows Server 2016 | 2016, 2012 R2 |
| Windows Server 2012 R2 | 2012 R2 |

Thus a **Server 2022 host cannot AVMA-activate a Server 2025 guest**.
The script continues deployment with an explicit activation-skipped warning
and reason instead of installing a Server 2022 key into a Server 2025 guest.
This restriction applies to **AVMA**; independently licensed retail, MAK or KMS
activation is a different method and is not attempted by this script.

The embedded Microsoft key catalog covers published LTSC Datacenter/Standard,
Datacenter: Azure Edition where available, and older Essentials guest editions.
The Datacenter keys for your current lab images are:

| Guest edition | Public AVMA key |
|---|---|
| Windows Server 2025 Datacenter | `YQB4H-NKHHJ-Q6K4R-4VMY6-VCH67` |
| Windows Server 2022 Datacenter | `W3GNR-8DDXR-2TFRP-H8P33-DV9BG` |

These generic keys do not grant a license or bypass the activated Datacenter
host requirement. Evaluation guests are skipped rather than converted with
DISM; unknown editions/builds are not guessed. The compatibility table includes
2012 R2, but this provisioning workflow still requires **Server 2016 or newer**
in the host/guest for PowerShell Direct and the existing nested-virtualization
prerequisites.

When activation is needed, the script enables and verifies **Data Exchange
(Key-Value Pair Exchange)** for only that VM, and starts its guest
`vmickvpexchange` service if needed. It does not re-enable host time
synchronization. Through PowerShell Direct, it installs the matching key using
the Windows licensing CIM API, requests activation if necessary, and checks
the selected licensing product reaches **LicenseStatus 1 (Licensed)** within
the verification window (120 seconds). A successful key-installation or
activation-method return alone is not reported as successful activation.
Existing licensed guest keys are preserved rather than replaced.

Some Windows licensing providers leave the CIM method's `ReturnValue` empty
or return no method output even when the requested operation takes effect.
The script warns once per operation when no status code is available, then
requires the selected AVMA product to be identified and its final
`LicenseStatus` to be `1`. Empty output alone is never treated as proof of
installation or activation. Explicit nonzero status codes, CIM exceptions, and
malformed result objects still stop the run.

Returned per-VM results include:
- `ActivationStatus`: `Activated`, `AlreadyActivated`, or `Skipped`.
- `ActivationReason`: explains verification or the exact skip reason.
- `LicenseStatus`: the observed Windows licensing status, when available.

Skipped AVMA does not prevent the remaining guest configuration/domain join.
Unexpected licensing/service errors or failed activation verification stop the
post-provisioning run with an explicit error; completed changes are preserved.
AVMA also runs when configuring explicitly selected existing VMs. WhatIf does
not inspect host licensing, enter a guest for activation, install keys or
change integration services. No host product key or host activation is changed.

To check licensing **inside a guest**, run:

```powershell
Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" |
    Where-Object { $_.LicenseIsAddon -eq $false } |
    Select-Object Name, LicenseFamily, LicenseStatus
```

### Retry only activation after guest configuration completed

If the guest's rename, domain membership, and OU verification succeeded but an
older script stopped with `AVMA key installation did not return a licensing
status code`, check the guest's licensing state before repeating provisioning.
The key might already be installed and Windows might already be Licensed.

Copy the updated `New-HyperVLab-Configured.ps1` from this folder to the Hyper-V host, then
load its functions without running provisioning. For a guest now named
`MSLABH01`, run this in **Administrator PowerShell on the Hyper-V host**:

```powershell
. 'C:\scripts\New-HyperVLab-Configured.ps1'

$local = Get-Credential `
    -UserName 'MSLABH01\Administrator' `
    -Message 'Enter the local Administrator password for the renamed guest'

$hostProfile = Get-LabAVMAHostProfile
Invoke-LabGuestAVMA -VMName 'MSLABH01' -Credential $local -HostProfile $hostProfile
```

Replace the VM name and local-account qualifier with the guest's current
names. After a successful rename, do not keep using the old `WIN-...` account
qualifier. The leading dot loads the script's functions; it does not create VMs
or reconfigure networking.

An already Licensed guest returns `Status = AlreadyActivated` and
`LicenseStatus = 1` without reinstalling its key. Otherwise, eligible guests
run the activation and final verification steps. This activation-only retry
does not repeat networking, domain join, or OU creation.

For activation failures, check Application event **12309** in the guest and
**12310** on the host. AVMA does not require guest internet connectivity; the
host/guest licensing handshake uses Hyper-V integration services.

### NIC device naming and guest adapter names

For newly created VMs, `New-HyperVLab-Configured.ps1` enables Hyper-V
**Advanced Features -> Device naming** (`-DeviceNaming On`) on every assigned
NIC, regardless of whether MAC address spoofing is enabled. Device Naming exposes
the host-side adapter name to a compatible Windows guest through the advanced
property **Hyper-V Network Adapter Name** (`HyperVNetworkAdapterName`).
It does **not** replace the NIC's normal driver/interface description.

The configured workflow separately uses MAC-address matching and
`Rename-NetAdapter` to set the guest-friendly adapter names:

| Value | Example with the default four NICs |
|---|---|
| Host-side VM adapter names | `NAT1`, `NAT2`, `SMB1`, `SMB2` |
| Guest adapter names (`Get-NetAdapter.Name`) | `mgmt1`, `mgmt2`, `smb1`, `smb2` |
| Guest interface description | Usually `Microsoft Hyper-V Network Adapter` |
| Guest advanced property `HyperVNetworkAdapterName` | Corresponding host-side name, such as `NAT1` |

Run these commands **inside the guest VM**, not on the Hyper-V host:

```powershell
Get-NetAdapter | Select-Object Name, InterfaceDescription

Get-NetAdapterAdvancedProperty -Name '*' |
    Where-Object RegistryKeyword -eq 'HyperVNetworkAdapterName' |
    Select-Object Name, DisplayName, DisplayValue
```

The second command lets you correlate a guest adapter such as `mgmt1` with its
host-side name such as `NAT1`; the name appears in `DisplayValue`, not the normal
`InterfaceDescription`. Resume mode for existing VMs skips VM/NIC creation,
so verify Device Naming on existing host adapters rather than assuming it was
enabled by the resume operation.

### Successful completion output

Each node finishes with messages confirming PowerShell Direct, firewall
stabilization, IST, its assigned address, and domain membership:

```text
PowerShell Direct is ready in 'HypNode11'.
Windows Firewall is disabled for Domain, Private, and Public profiles in 'HypNode11' after 9 verification attempt(s).
Time zone 'India Standard Time' is configured in 'HypNode11'.
Configured HypNode11 as 10.151.33.4 and joined it to mylab.local.
```

After all selected nodes complete, the script returns a summary object per VM.
To display the returned results as a table, select the desired columns:

```powershell
$results = .\New-HyperVLab-Configured.ps1
$results | Format-Table VMName, IPAddress, Domain, OU, ActivationStatus -AutoSize
```

```text
VMName    IPAddress   Domain       OU        ActivationStatus
------    ---------   ------       --        ----------------
HypNode10 10.151.33.3 mylab.local   HypNodeOU Activated
HypNode11 10.151.33.4 mylab.local   HypNodeOU Activated
HypNode12 10.151.33.5 mylab.local   HypNodeOU Activated
```

The `Configured ... joined it to mylab.local` message is emitted only after the
script verifies the restarted guest name, domain membership, AD computer
account, and OU placement. An `Add-Computer` warning that changes take effect
after restart is expected; the script schedules that restart automatically and
waits for the Windows boot time to change and PowerShell Direct to return before
reporting success. A responsive session before the scheduled restart is not
treated as completion. Rename and domain join are separate operations; the
script does not use `Add-Computer -NewName`, which can leave a joined computer
with its old name if the subsequent domain rename fails.

Disabling all Windows Firewall profiles substantially reduces guest isolation
and should be limited to this controlled lab. A domain Group Policy can
re-enable the firewall after the two-minute stabilization window. The script
surfaces an error if its final enforcement attempt cannot keep all three
profiles disabled.

Automatic address checks reduce collision risk but cannot prove that an offline,
unregistered device has not been statically assigned an address. For reliable
production use, reserve this pool in DHCP/IPAM and keep DNS records current.

PowerShell Direct requires Windows 10 / Windows Server 2016 or newer in the
guest, enabled Hyper-V VM Session integration service, and a valid local guest
credential. The generalized image must complete first-boot setup automatically
and leave the local Administrator account enabled.

If VMs from an interrupted run already exist, complete OOBE manually if needed
and verify PowerShell Direct before resuming only those VMs. The following
example is for unjoined guests that accept the same local credential. For
guests already joined to the domain, use their actual Windows account names as
described below. Replace the example names with the actual VMs:

```powershell
$vmNames = 'HypNode09','HypNode10','HypNode11','HypNode12'
$credential = Get-Credential `
    -UserName 'Administrator' `
    -Message 'Enter the local Administrator password used during OOBE'

$vmNames | ForEach-Object {
    Invoke-Command -VMName $_ -Credential $credential -ScriptBlock {
        [pscustomobject]@{
            Hostname = hostname
            Identity = whoami
        }
    }
}

& 'C:\scripts\New-HyperVLab-Configured.ps1' `
    -ConfigureExistingVMName $vmNames
```

If part of the batch already completed successfully before a failure, resume
only the unfinished VMs and reuse the OU printed by the failed run:

```powershell
& 'C:\scripts\New-HyperVLab-Configured.ps1' `
    -ConfigureExistingVMName 'HypNode10','HypNode11','HypNode12' `
    -ExistingOUName 'HypNodeOU'
```

### When PowerShell Direct reports "The credential is invalid"

A normal Windows sign-in screen is **not** OOBE. If local sign-in works but
PowerShell Direct rejects the same password, check the username's computer
qualifier before changing the password or rebuilding the template.

The Hyper-V VM name and the Windows computer name can differ after a failed
rename. For example, VM `MSLABH01` might still be the domain-joined Windows
computer `WIN-REFERENCE`. In that case, use
`WIN-REFERENCE\Administrator` for its local account, not
`MSLABH01\Administrator`. Do not assume that `.\Administrator` resolves
correctly over PowerShell Direct just because it works at the guest console.

Inside the guest, sign in locally and check:

```powershell
hostname
whoami
Get-Service vmicvmsession | Select-Object Name, Status, StartType
```

Then test from **Administrator PowerShell on the Hyper-V host**, substituting
the actual Windows computer name:

```powershell
$local = Get-Credential `
    -UserName 'WIN-REFERENCE\Administrator' `
    -Message 'Enter the working local guest Administrator password'

Invoke-Command -VMName 'MSLABH01' -Credential $local -ScriptBlock {
    hostname
    whoami
} -ErrorAction Stop
```

Do not continue until this succeeds. A computer-qualified local credential is
specific to that Windows computer; do not reuse it for other guests with
different Windows names. Domain credentials are supplied separately for AD
operations.

When resuming existing VMs, the script stops at an initial invalid-credential
error instead of retrying authentication for the full readiness timeout.
Newly created guests still get time to create their local accounts during
unattended first boot. Scheduled reboots also continue retrying because a
renamed account's computer qualifier may not work until Windows restarts.
Other readiness failures report the last connection error rather than assuming
the guest is at OOBE.

### Recover a domain join that succeeded but failed to rename

An error such as `successfully joined to the new domain ... but renaming it ...
failed ... The directory service is busy` means the join and rename did not
both complete. It does not mean the reference image needs to be generalized
again. Do not delete the VM or its AD computer account just to retry.

1. Copy the updated `New-HyperVLab-Configured.ps1` from this folder to
   `C:\scripts\New-HyperVLab-Configured.ps1` on the Hyper-V host.
   `Manage-HyperVLab.ps1` loads the configured provisioner from its own
   directory, so updating only the menu script will not apply this fix.
2. Restart the failed guest once to complete the successful domain join before
   attempting its domain rename. From an elevated PowerShell window **inside
   that guest**, run:

   ```powershell
   Restart-Computer -Force
   ```

3. After the guest returns, verify PowerShell Direct as described above. Run
   the updated provisioner **on the Hyper-V host**, targeting the partially
   joined VM alone with its verified local credential and the existing OU:

   ```powershell
   & 'C:\scripts\New-HyperVLab-Configured.ps1' `
       -ConfigureExistingVMName 'MSLABH01' `
       -ExistingOUName 'MSLABHOU' `
       -LocalAdministratorCredential $local
   ```

   `$local` is the credential verified in the preceding troubleshooting section.
   Replace the VM and OU names with those printed by your failed run, and
   supply an AD credential allowed to rename the domain computer account.
4. Once that VM completes successfully, resume the remaining unjoined VMs
   separately so they do not receive the first VM's computer-qualified
   credential:

   ```powershell
   & 'C:\scripts\New-HyperVLab-Configured.ps1' `
       -ConfigureExistingVMName 'MSLABH02','MSLABH03','MSLABH04' `
       -ExistingOUName 'MSLABHOU'
   ```

   Enter the template's local Administrator credential for those guests when
   prompted. If another guest also requires a computer-qualified account,
   verify and resume it separately. Do not select the menu's create option to
   resume; it allocates a new batch rather than selecting existing VMs.

An existing member of the intended domain is not joined again. If its name is
wrong, the script renames it using the supplied domain credential, verifies a
reboot, and checks its final name, domain, and existing OU placement. Membership
in a different domain or placement in a different OU is reported as an error;
the script does not silently move the computer account.

Resuming re-applies guest network configuration and may select new available IP
addresses. Exclude VMs that already completed successfully. If the domain rename
still fails after the initial reboot, inspect the guest's
`C:\Windows\Debug\NetSetup.log` and domain-controller health before retrying.
The error is surfaced rather than treated as a successful deployment.

The variant preserves completed changes if a later VM fails, and reports the VM
where configuration stopped. Its `-WhatIf` mode runs only the base provisioning
preview and does not prompt for credentials, create an OU, or enter any guest.

References: [PowerShell Direct](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/manage/manage-windows-virtual-machines-with-powershell-direct),
[Add-Computer](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/add-computer).

## Safe validation

Before a real deployment:

1. Validate the parent using the disposable-child procedure in the
   [template guide](./Prepare-HyperVLabTemplate.README.md#8-test-the-new-parent-before-a-larger-deployment).
2. Run `.\Manage-HyperVLab.ps1 -WhatIf` and select option 1. Creation preview
   collects settings and reads host state but does not create VMs, enter
   guests, create an OU, or change guest configuration.
3. Check the planned storage paths, parent, VM names, switches, and resource
   allocations. Also verify the documented domain/network defaults against
   your actual lab before removing `-WhatIf`.
4. Deploy a small disposable batch before a larger run.

Cleanup `-WhatIf` is also non-mutating, but guest-aware preview requires
credentials and performs read-only guest/DC discovery. Review its identity
and storage plan before authorizing destructive cleanup.
