# Creating an unattended Windows parent for the nested Hyper-V lab

This guide explains how to build a generalized Windows parent VHDX that can
complete its first boot without stopping at the **Hi there** OOBE screen.
`New-HyperVLab-Configured.ps1` requires first-boot setup to finish before it can
connect through PowerShell Direct and configure the guest.

`Prepare-HyperVLabTemplate.ps1` creates and validates the Sysprep answer file.
It does **not** run Sysprep or modify an existing parent VHDX.

The deployed children provide a foundation for installing nested Hyper-V,
building a failover cluster, and configuring Storage Spaces Direct (S2D).
Those roles, cluster creation, and S2D configuration are not performed by the
template helper or the configured provisioner.

Preparing an unattended parent once reduces repeated per-VM setup: after you
choose resources and enter credentials on the host, deployed children can
complete first boot and continue configuration without console interaction.
Use [Manage-HyperVLab.ps1](./Manage-HyperVLab.ps1) on the host as the normal
entry point; it starts [New-HyperVLab-Configured.ps1](./New-HyperVLab-Configured.ps1)
for creation. See the [package quick start](./README.md#recommended-unattended-deployment-workflow)
for the overall sequence and environment defaults.

## Important parent-disk safety

Do not boot, mount, edit, move, replace, or re-Sysprep a parent VHDX that already
has differencing children. Changing the parent can make every dependent child
disk unusable.

Prepare a new standalone reference VM and publish its VHDX as a new parent
image. Existing lab VMs can continue using the previous parent.

## Prerequisites

- A temporary Generation 2 Hyper-V reference VM.
- A standalone VHDX that is not the parent of existing differencing disks.
- A supported x64 Windows image. PowerShell Direct requires Windows 10,
  Windows Server 2016, or newer.
- Hyper-V integration services enabled in the guest, including the
  **Hyper-V PowerShell Direct Service** (`vmicvmsession`).
- Local Administrator access inside the reference VM.
- No pending restart, Windows Update, application installation, or servicing
  operation when Sysprep is started.
- Enough free storage for the reference VHDX and future differencing children.

The reference VM should not be joined to `mylab.local` or another domain.

## 1. Create the reference VM

Create a temporary Generation 2 VM using a standalone dynamically expanding
VHDX. Install the same Windows edition that the lab nodes should run.

Suggested reference-VM settings:

- Generation 2.
- Secure Boot appropriate for the selected Windows image.
- Static or Dynamic Memory sufficient for installation and updating.
- One temporary network adapter for Windows Update and software installation.
- No checkpoints when the final image is generalized.

Do not use your existing production parent VHDX directly.

## 2. Install and customize Windows

Complete Windows installation normally, then:

1. Install current Windows updates.
2. Install required applications, roles, tools, and drivers.
3. Remove temporary files and installation media.
4. Confirm Device Manager has no unexpected device errors.
5. Confirm the built-in `Administrator` account is available.
6. Keep the computer in a workgroup.
7. Restart until there are no pending restart requirements.

Do not assign the final node name, domain membership, or permanent node IP
address in the reference image. The end-to-end provisioning script configures
those settings after deployment.

## 3. Copy the preparation helper into the reference VM

Copy `Prepare-HyperVLabTemplate.ps1` into the reference VM, for example:

```text
C:\HyperVLab\Prepare-HyperVLabTemplate.ps1
```

Open an elevated Windows PowerShell window inside the reference VM:

```powershell
Set-Location C:\HyperVLab
Set-ExecutionPolicy -Scope Process Bypass
.\Prepare-HyperVLabTemplate.ps1
```

The execution-policy change applies only to that PowerShell process.

## 4. Enter the local Administrator password

The helper prompts securely for the built-in `Administrator` credential. Enter
the password that `New-HyperVLab-Configured.ps1` will later use for PowerShell
Direct.

The helper does not contain or hardcode a password. It generates Windows
answer-file password values with `PlainText` set to `false`.

> Hidden answer-file passwords are encoded, not encrypted. Anyone with access
> to the answer file or parent VHDX should be treated as having access to the
> local Administrator credential.

Use a lab-specific password and rotate it after domain join. Windows LAPS is
recommended for ongoing local Administrator password management.

## 5. Review the generated answer file

The default output is:

```text
C:\HyperVLab\Unattend.xml
```

The helper validates that the file is well-formed XML and contains the required
OOBE settings. It configures:

- Input, system, UI, and user locale: `en-IN`.
- Time zone: `India Standard Time`.
- Automatic computer-name generation during first boot.
- OOBE page suppression.
- Built-in Administrator password configuration.
- One automatic local Administrator logon.

### Example console output

After you enter the Administrator credential, a successful run looks like this
(using `C:\HyperVLab` as the working directory and `C:\Windows` as the Windows
directory):

```text
PS C:\HyperVLab> .\Prepare-HyperVLabTemplate.ps1
WARNING: The password values are hidden, not encrypted. Protect and delete the unattend file after the template is generalized.

Review the generated file, then run this command inside the reference VM as Administrator:
& "C:\Windows\System32\Sysprep\Sysprep.exe" /generalize /oobe /mode:vm /shutdown /unattend:"C:\HyperVLab\Unattend.xml"

UnattendPath                 SysprepCommand
------------                 --------------
C:\HyperVLab\Unattend.xml     & "C:\Windows\System32\Sysprep\Sysprep.exe" /generalize /oobe /mode:vm /shutdown /unattend:"C:\HyperVLab\Unattend.xml"
```

The warning is expected: the password values are encoded, not encrypted.
`UnattendPath` identifies the generated answer file, and `SysprepCommand` is the
command to run after reviewing it. This output does **not** mean Sysprep has
already run. PowerShell may truncate the command in the table; use the complete
command printed above the table or the command in
[step 6](#6-run-sysprep-after-reviewing-the-answer-file).

### Review and customize the answer file

Review the non-password settings:

```powershell
Get-Content C:\HyperVLab\Unattend.xml
```

Do not replace the encoded password values manually. To change the password,
run the helper again with `-Force`:

```powershell
.\Prepare-HyperVLabTemplate.ps1 -Force
```

Optional locale and time-zone overrides:

```powershell
.\Prepare-HyperVLabTemplate.ps1 `
    -InputLocale 'en-US' `
    -SystemLocale 'en-US' `
    -UILanguage 'en-US' `
    -UserLocale 'en-US' `
    -TimeZone 'UTC' `
    -Force
```

## 6. Run Sysprep after reviewing the answer file

The helper prints the Sysprep command but does not execute it. Run the following
from an elevated PowerShell window inside the reference VM:

```powershell
& "$env:SystemRoot\System32\Sysprep\Sysprep.exe" `
    /generalize `
    /oobe `
    /mode:vm `
    /shutdown `
    /unattend:"C:\HyperVLab\Unattend.xml"
```

The options mean:

- `/generalize`: removes machine-specific identity information.
- `/oobe`: runs the configured OOBE pass on the next boot.
- `/mode:vm`: optimizes generalization for redeployment to a matching VM
  environment.
- `/shutdown`: powers off the reference VM when Sysprep succeeds.
- `/unattend`: applies the generated answer file.

Do not use the reference VM while Sysprep is running. Wait for it to shut down.

## 7. Preserve the generalized VHDX

After Sysprep shuts down the reference VM:

1. Do not start that VM again.
2. Ensure the VM is fully off, not saved or paused.
3. Remove any checkpoints before publishing the image.
4. Copy or move the standalone OS VHDX to the new template location.
5. Give it a clear versioned name, such as:

   ```text
   D:\Differencing\Template2025-2026-10.vhdx
   ```

6. Restrict write access so administrators do not accidentally modify it.
7. Keep the answer file and parent VHDX protected because they contain a
   recoverable local Administrator credential.

Once differencing children exist, do not alter the parent VHDX.

## 8. Test the new parent before a larger deployment

Create one disposable differencing disk and test VM before deploying several
nodes:

```powershell
New-VHD `
    -Path 'D:\HyperV\TestNode-OS.vhdx' `
    -ParentPath 'D:\Differencing\Template2025-2026-10.vhdx' `
    -Differencing
```

Start the disposable VM and verify:

1. The **Hi there** screen does not require interaction.
2. Windows completes first boot.
3. The local Administrator password works.
4. PowerShell Direct works from the Hyper-V host:

   ```powershell
   $credential = Get-Credential `
       -UserName 'Administrator' `
       -Message 'Enter the template local Administrator password'
   Invoke-Command -VMName 'TestNode' -Credential $credential -ScriptBlock {
       $env:COMPUTERNAME
   }
   ```

5. The VM reaches the desktop or completes its one automatic logon.

Delete the disposable test VM and child VHDX after validation. Do not delete the
new parent.

## 9. Run the end-to-end lab provisioning script

Copy `Manage-HyperVLab.ps1`, `New-HyperVLab-Configured.ps1`, and
`Remove-HyperVLabNodes.ps1` together into a folder on the Hyper-V host, for
example `C:\scripts`. Run the menu from an elevated Windows PowerShell window:

```powershell
Set-Location C:\scripts
.\Manage-HyperVLab.ps1 -WhatIf
```

Choose **1** to preview creation. After reviewing the plan and lab defaults,
run the menu without `-WhatIf` and choose **1** to deploy:

```powershell
.\Manage-HyperVLab.ps1
```

For domain/network overrides or resume mode, invoke the configured script
directly instead:

```powershell
.\New-HyperVLab-Configured.ps1
```

When prompted for the local Administrator credential, enter the same password
used while generating `Unattend.xml`.

The script first prompts for a VM naming prefix. It then provisions the VMs,
waits for PowerShell Direct, disables and verifies all Windows Firewall profiles,
configures guest NICs and addressing, creates the derived/serialized AD OU
(`MSLABVM` -> `MSLABOU`, then `MSLABOU01` on a later deployment), renames the nodes, and joins them to
`mylab.local`. After the domain-join restart, it re-disables and verifies the
firewall every 15 seconds for two minutes. It also sets and verifies
`India Standard Time` through PowerShell Direct before and after domain join.

For new VMs, the configured script also enables Hyper-V Device Naming.
Host-side NIC names such as `NAT1` and `SMB1` are exposed inside compatible guests
through the **Hyper-V Network Adapter Name** advanced property, not the normal
NIC description. Guest-friendly names are separately renamed to `mgmt1`,
`mgmt2`, `smb1`, `smb2`, etc. The normal interface description usually remains
`Microsoft Hyper-V Network Adapter`.
See [NIC device naming and guest adapter names](./README.md#nic-device-naming-and-guest-adapter-names)
for guest verification commands and the distinction between these values.

The configured script also checks the host and guest OS version/edition for
**Automatic Virtual Machine Activation (AVMA)** after the guest's domain-join
restart. AVMA requires an activated, non-evaluation Windows Server Datacenter
Hyper-V host and a supported non-evaluation guest. For example, a Server 2022
host cannot AVMA-activate a Server 2025 guest; deployment continues with a clear
activation-skipped reason. Matching public AVMA keys are installed only when
eligible, existing licensed guest keys are preserved, and activation is verified
as `LicenseStatus 1`. The script does not convert evaluation images or change
the host's license. Use a properly licensed, non-evaluation template for AVMA.
See [Automatic VM activation (AVMA)](./README.md#automatic-vm-activation-avma)
for the compatibility table, key selection, verification and failure behavior.

## Continue with Hyper-V, Failover Clustering, and S2D

After guest provisioning and verification finish, install the required
Hyper-V and Failover Clustering roles/features inside the intended nodes,
validate the cluster configuration, create the cluster and quorum, then
configure S2D and its storage volumes. These are separate lab-building steps,
not part of the scripts' unattended preparation workflow.

Choose the required data disks during VM provisioning and leave those intended
for S2D pooling empty, unpartitioned, and unformatted. See the
[automation boundary and next steps](./README.md#automation-boundary-and-next-steps)
and Microsoft's
[Storage Spaces Direct deployment guide](https://learn.microsoft.com/en-us/windows-server/storage/storage-spaces/deploy-storage-spaces-direct)
before configuring the storage pool.

## Recovering VMs already stopped at OOBE

For VMs already showing the **Hi there** screen:

1. Complete OOBE manually on each VM.
2. Set the built-in Administrator password to the credential supplied to the
   configured script.
3. List the affected VMs and create a fresh credential:

   ```powershell
   $vmNames = 'HypNode09','HypNode10','HypNode11','HypNode12'
   $credential = Get-Credential `
       -UserName 'Administrator' `
       -Message 'Enter the local Administrator password used during OOBE'
   ```

4. Verify PowerShell Direct on every affected VM:

   ```powershell
   $vmNames | ForEach-Object {
       Invoke-Command -VMName $_ -Credential $credential -ScriptBlock {
           [pscustomobject]@{
               Hostname = hostname
               Identity = whoami
           }
       }
   }
   ```

5. If the original script is still waiting, it should continue after
   PowerShell Direct becomes available. If it has timed out, use resume mode:

   ```powershell
   & 'C:\scripts\New-HyperVLab-Configured.ps1' `
       -ConfigureExistingVMName $vmNames
   ```

   If some nodes were already joined before the failure, select only the
   remaining nodes and reuse the OU created by the interrupted run:

   ```powershell
   & 'C:\scripts\New-HyperVLab-Configured.ps1' `
       -ConfigureExistingVMName 'HypNode10','HypNode11','HypNode12' `
       -ExistingOUName 'HypNodeOU'
   ```

Do not rerun the script without `-ConfigureExistingVMName`, because the default
workflow provisions additional VMs.

## Troubleshooting

### The VM still displays OOBE

- Confirm Sysprep was run with the generated `/unattend` path.
- Confirm the file was generated before Sysprep.
- Review:

  ```text
  C:\Windows\Panther\UnattendGC\setupact.log
  C:\Windows\Panther\UnattendGC\setuperr.log
  C:\Windows\System32\Sysprep\Panther\setupact.log
  C:\Windows\System32\Sysprep\Panther\setuperr.log
  ```

- Confirm the Windows edition supports the configured OOBE settings.

### Sysprep fails

- Finish Windows Update and restart.
- Remove pending package or application installation operations.
- Remove Microsoft Store applications that were updated for only one user.
- Review the Sysprep Panther logs shown above.
- Build a new clean reference VM if the image has already been generalized and
  booted repeatedly.

### PowerShell Direct authentication fails

- Confirm first boot and OOBE completed.
- Confirm the VM is running on the local Hyper-V host.
- Confirm the `vmicvmsession` service is enabled inside the guest.
- Confirm the supplied local Administrator password matches the one used in
  the answer file.
- Confirm the built-in Administrator account is enabled.
- A normal sign-in screen is not OOBE. If local sign-in works, run `hostname`
  and `whoami` in the guest and use its actual Windows computer-qualified
  account for PowerShell Direct; it may differ from the Hyper-V VM name.
- See [PowerShell Direct credential troubleshooting](./README.md#when-powershell-direct-reports-the-credential-is-invalid)
  before retrying an interrupted domain join.

### The parent already has child disks

Do not repair or update that parent in place. Build and publish a new versioned
parent VHDX, then use the new path for future deployments.

## Security notes

- Treat the unattend file and generalized VHDX as credential-bearing assets.
- Limit NTFS permissions to the Hyper-V administrators and required Hyper-V
  service identities.
- Do not commit generated `Unattend.xml` files to source control.
- Do not email or share the answer file.
- Rotate the local Administrator password after deployment.
- Prefer Windows LAPS after the nodes join Active Directory.
