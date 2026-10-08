# Customer Environment Readiness and Test Runbook

| Document Information | Detail |
| --- | --- |
| Date | 30 September 2026 |
| Audience | Customer infrastructure, security, backup, application, and change teams; implementation engineers |
| Purpose | Prepare, authorize, execute, and accept the first controlled customer-environment test |
| Companion guide | [CUSTOMER-OVERVIEW.md](CUSTOMER-OVERVIEW.md) |
| Scope | Current Windows Server upgrade automation; no new production-safety features are implied |

## 1. Decision Before Execution

**No checklist, script, or successful lab run can guarantee a first-attempt operating system upgrade.** Success depends on the target's servicing state, hardware, drivers, applications, security policy, media, and recovery arrangements. A previous successful Windows Server 2019-to-2022 lab upgrade does not certify the customer's environment.

Recommended sequence:

1. Complete the inventory, configuration checks, and recovery review below without launching Setup.
2. Validate the exact approved release on a representative non-production server in the customer environment, with equivalent security policy and network controls.
3. Record the result and resolve all unexpected findings.
4. Authorize a production pilot only through the customer's change process, with named recovery and application owners available.

A clone must be isolated or managed using the customer's supported cloning procedure so that duplicate computer identities, IP addresses, agents, or applications do not interfere with production. A newly installed test VM without the same applications and policies is not a representative rehearsal.

**Do not use the main orchestrator as a connectivity test.** Once its checks and backup stage finish, it can start Windows Setup without another approval prompt. There is no full assessment-only, dry-run, pause-before-Setup, or guaranteed monitoring-only switch in the current release. The separate readiness script checks reboot blockers only.

## 2. Required Customer Information

Complete this record before deciding the connection method or launch command. Do not place passwords, private keys, or recovery keys in it.

| Item | Required Information / Evidence |
| --- | --- |
| Approved release | Repository commit/tag, package checksum or manifest, review owner, and approved command line |
| Server A | Management-server FQDN, IP, Windows version, Windows PowerShell version/architecture, and network segment |
| Server B | Target FQDN, IP, source OS version/build, edition, language, installation type, and processor architecture |
| Target OS | Intended version/build/edition, supported upgrade path, ISO source, and checksum |
| Business role | Applications, databases, roles/features, dependencies, owners, and criticality |
| Deployment | Physical/VM, hypervisor and guest-tools versions, firmware/boot mode, storage and network drivers |
| Identity | Domain/trust relationship or workgroup, approved execution account, and authorization method |
| Security controls | WinRM transport, certificate requirements, firewall scope, execution policy, application control, EDR, and encryption |
| Storage | C: free space, recovery/system partition health, local media drive, local backup drive, and backup capacity |
| Recovery | Backup identifier, included disks/data, restore-test evidence, recovery location, RTO/RPO, console access, and recovery owner |
| Operations | Window, dependencies to stop/start, monitoring arrangements, escalation contacts, and latest recovery decision time |
| Acceptance | OS, application, security, licensing, backup, and monitoring checks with named sign-off owners |

Unknown, unverified, or inaccessible evidence is not a pass. Use an approved exception process where applicable; exceptions cannot make an unsupported upgrade path supported.

## 3. Release and Server A Readiness

- Use a dedicated, stable management server or approved jump host that will not sleep, restart, disconnect from its network, or lose its execution session during the test. Check scheduled patching and forced session logoff policies.
- Run from a local folder containing the complete approved release, not a mixture of versions or scripts edited directly on the customer test copy.
- Preserve the ServerA-Orchestrator and sibling ServerB-Target layout, or explicitly set the source-file path. Confirm all six target-side files listed in the overview exist.
- Use 64-bit Windows PowerShell 5.1 for this validation baseline, launched with appropriate elevation. Do not substitute PowerShell 7, a constrained endpoint, or a wrapper service without separate validation.
- Confirm `powershell.exe` and the normal Windows utilities are resolvable in the execution environment. Child PowerShell processes are used for bounded remote probes.
- Confirm approved script execution on both servers. A process-level execution-policy bypass cannot override Group Policy, WDAC, AppLocker, EDR, or endpoint authorization. Do not weaken these controls without security approval.
- The target code uses operations such as COM access and `Add-Type` for backup privileges. A constrained-language or restricted remoting environment needs specific validation; do not assume the default script will work there.
- Confirm write access and capacity for Server A's local logs/status mirror under `C:\ProgramData\OSUpgradeAutomation\OrchestratorLogs`.
- Run the offline regression suite on Server A before testing remoting. It exercises mocked logic and startup paths, not the customer's live upgrade or recovery process.
- Keep customer raw logs, registry backups, credentials, and recovery material out of GitHub and shared release packages unless explicitly approved and appropriately protected.

Local inspection commands on Server A; these do not start an upgrade:

```powershell
$PSVersionTable.PSVersion
[Environment]::Is64BitProcess
$ExecutionContext.SessionState.LanguageMode
Get-ExecutionPolicy -List
Get-Command powershell.exe, New-PSSession, Invoke-Command, Copy-Item, Start-Job
```

From the approved package's OSupgradeAutomation directory, and with execution already authorized:

```powershell
powershell.exe -NoProfile -File .\Tests\Test-ProgressAndReadiness.ps1
```

Expected evidence: supported shell, all regression checks pass, and the package matches the approved release. If policy blocks the suite, resolve that with the security owner; it is not a reason to disable enforcement globally.

## 4. Identity and Remote Access

### Account and Authorization

- Use a customer-approved account with the necessary local administrative rights on Server B, and appropriate local access on Server A. Domain Administrator membership is not inherently required.
- Confirm the account can authenticate to the actual PowerShell endpoint, read system information, copy the companion files, mount local media, manage the automation's registry key, and register elevated SYSTEM scheduled tasks.
- Confirm backup privileges required by registry/System State operations are available. Merely being able to run a remote command does not prove all these permissions.
- SYSTEM on Server B must be able to read the local mounted media and persistent scripts, write status/logs, and execute the Setup/monitor/cleanup tasks. User-session mapped drives are not suitable.
- Default domain authentication should use the customer-approved name and trust configuration. Prefer an FQDN; using an IP address changes authentication/certificate behavior and can prevent Kerberos.
- Verify DNS resolution and time synchronization on both servers and the identity infrastructure. Avoid inconsistent aliases or SPNs.
- Workgroup or untrusted-domain access requires a separately agreed authentication configuration and explicit credential test. Prefer correctly validated HTTPS. Do not assume TrustedHosts is always necessary when trusted HTTPS is used; never add `*` as a blanket workaround.
- Do not enable Basic authentication, AllowUnencrypted, CredSSP, unrestricted delegation, or broad UAC bypasses merely to make this workflow run. The design uses local target media/backup paths and does not require a second-hop file share.

### WinRM Configuration

Customer administrators must configure remoting before the test, using the approved baseline or configuration-management process. The upgrade scripts do not establish the listener, certificate, firewall policy, or remote endpoint permissions.

For HTTPS, confirm that the target listener is bound to an unexpired certificate with a private key, Server Authentication usage, and a name matching the FQDN used by Server A. Server A must trust its issuer and have the certificate validation/revocation access required by policy.

The orchestrator supports the standard HTTP/5985 and HTTPS/5986 routes, not a configurable custom WinRM port or endpoint name. `-UseSSL` selects HTTPS. Without it, HTTP is tried first and HTTPS is the fallback. WinRM authentication and message protection must still follow customer policy; HTTP does not itself mean that authenticated WinRM payloads are sent in plaintext.

Both a long-running kickoff session and an independent status-reading connection must work concurrently. Validate normal remoting quotas, session lifetime, and application-control behavior with the approved account. Do not increase quotas or security exceptions without evidence of the specific need.

Read-only inspection on Server B, locally or through an already approved management channel:

```powershell
Get-Service WinRM, Schedule, Winmgmt, RpcSs, EventLog
Get-ChildItem WSMan:\localhost\Listener
Get-PSSessionConfiguration | Select-Object Name, PSVersion, Permission
```

If configuration is missing, stop for the customer platform/security team to enable the approved remoting endpoint and source-scoped rules. Do not run a blanket remoting-enablement command on production without reviewing the listeners and firewall rules it creates.

## 5. Network and Dependency Matrix

Only request the routes actually required by the approved design. Do not open every optional status channel simply to eliminate warnings.

| Route | Purpose | Required for This Test? |
| --- | --- | --- |
| Server A -> Server B, TCP 5986 | WinRM over HTTPS | Required when using the recommended validated-HTTPS example below. |
| Server A -> Server B, TCP 5985 | WinRM over HTTP under approved authentication policy | Alternative when HTTP is explicitly approved. Both ports do not need to be opened. |
| Server A -> Server B, TCP 445 | SMB administrative-share status reading | Optional when independent WinRM JSON reading is working. Initial staging uses a PowerShell session, not a required SMB copy. |
| Server A -> Server B, TCP 135 plus the target's configured dynamic RPC range | DCOM/WMI registry fallback | Optional. Modern Windows commonly uses TCP 49152-65535 unless constrained by policy; confirm actual configuration rather than requesting a blanket range. |
| Server A -> Server B, ICMP | Connectivity hint | Optional. Ping failure is not the upgrade gate or proof of a failed server. |
| Servers -> approved DNS, domain/time infrastructure | Name resolution, authentication, and time | Required as dictated by the customer's domain/trust design; retain existing approved dependencies. |
| Servers -> approved certificate-validation endpoints | CA chain, CRL/OCSP checks where required | Required for the selected certificate policy; routes depend on the customer's PKI. |
| Server B -> approved WSUS/update source | Accurate patch assessment and separately authorized patching | Validate the actual configured endpoints. An unreachable source can cause fallback checks, warnings, or delays. |
| Server B -> approved activation infrastructure | License activation/verification | Required as applicable, for example KMS or domain-based activation; the automation does not activate Windows itself. |
| Operators -> approved console/hypervisor or out-of-band interface | Recovery when guest networking is unavailable | Required. RDP alone is not an adequate recovery channel. |

Scope target firewall and network rules to Server A and the required infrastructure. Network owners must confirm stateful return traffic, DNS/FQDN behavior, inspection policies, and rule persistence after restart. Do not rely on temporary exceptions that expire during the window.

No general Internet access is required to download the script/ISO during execution when they are pre-positioned. This does not mean every Windows assessment/Setup component avoids network attempts. The current script disables Setup Dynamic Update and requests telemetry disablement; restricted-egress behavior still needs rehearsal, and media currency must be handled before the run.

## 6. Server B, Workload, and Media Readiness

### Supported Target

- Confirm the source/target combination against current Windows Server upgrade documentation and the application/hardware vendors' support requirements. The validated pilot was Server 2019 to Server 2022; do not extrapolate it to all versions.
- This script blocks domain controllers and servers detected by its failover-clustering check. A server with the clustering feature installed may be rejected even when it is not an active cluster node. Use a separately approved method for such systems.
- Confirm matching edition, installation type (Server Core versus Desktop Experience), language, architecture, and suitable licensing/media channel. Edition conversion, evaluation conversion, and Core/GUI changes are not covered by the tested workflow.
- Do not use this baseline for an upgrade to evaluation media, a prerelease source, Windows Storage Server, or native boot-from-VHD. Native boot-from-VHD is different from an ordinary VM using a virtual disk. Hosted/cloud targets require confirmation of the provider's supported upgrade procedure as well as the Windows requirements.
- Confirm the target is not already at the intended OS version. Same/older media is rejected when identified. Review old automation tasks/state and preserve prior evidence before a new attempt; do not erase it as a troubleshooting shortcut.
- Verify compatibility of storage/network drivers, firmware, hypervisor/guest tools, backup agents, EDR/antivirus, encryption, filter drivers, application runtimes, and installed roles with the target OS.
- On VMware, confirm Tools is running and meets the configured version threshold (default 12.0.0) and the vendor's supported combination. Do not upgrade guest tools or drivers mid-run without a separately approved plan.
- Identify workload-specific steps: application/database quiescing, load-balancer drain, scheduled jobs, replication, vendor agents, and restart order. The script does not perform application-aware coordination for every workload.
- If Server B is a Hyper-V host rather than a guest VM, back up its VMs and migrate or shut them down according to the supported host-upgrade procedure. Do not leave guest VMs running during the host upgrade. Review virtual-switch and management dependencies separately.
- Identify any NIC Teaming and the exact networking implementation. Microsoft guidance requires NIC Teaming to be disabled before an in-place upgrade and allows it to be re-enabled afterward. The customer network/platform team must plan the appropriate procedure, preserve configuration, and confirm console or alternate management access before making changes; do not disable a team blindly over its only remote connection.
- For RDS licensing, obtain a supported, application-consistent backup and a licensing recovery plan. The script's best-effort copy of a potentially open licensing database is not sufficient recovery assurance.
- For BitLocker or other encryption, verify recovery-key access through approved secure storage and follow the vendor-supported upgrade procedure. Plan any suspension/resumption separately; do not disable protection by default or put recovery keys in logs.

### Operating System Health

- Complete approved patching and pending installer/servicing activity before the window. Avoid overlapping updates, backup jobs, and another Setup process.
- Run and review DISM component-store health and SFC results before the upgrade run. Resolve corruption and repeat checks until the result is conclusive. SFC can repair files; this is an authorized maintenance activity, not a read-only inventory command.
- If a repair or feature installation requests a restart, perform an approved restart and reassess. Do not automatically run repair commands as part of a connectivity test.
- Review disk/storage errors, servicing failures, unexpected restarts, and relevant event logs. Confirm sufficient free system/recovery partition space for the selected upgrade, not only the script's C: check.
- Capture the pre-upgrade system/role inventory, IP/DNS/gateway configuration, routes, adapter/team/switch configuration, application/service baseline, activation state, and relevant policy settings. Store this evidence securely off the target for comparison and recovery. Do not include private keys or credentials in ordinary diagnostic logs.
- Resolve pending servicing, Windows Update, and file rename/delete operations. If the same entries return after restart, investigate the owning installer or agent. Never clear the registry queue to force a pass.
- Review orphaned-profile findings with the customer. Restore identity connectivity or use approved profile cleanup as appropriate; do not delete user profiles simply because a lookup failed once.
- Confirm Windows activation and the licensing plan, and RDS Session Host licensing configuration where applicable. A warning-only script result does not remove licensing obligations.

### Storage and Installation Media

- The current package assumes a conventional Windows installation on C: in several checks/paths. A non-C: system installation requires separate code review and is not part of this baseline.
- Confirm at least the configured 32 GB free-space threshold on C:, plus the actual headroom needed by the image, applications, migration, Windows.old, and logs. There is no universal safe backup-drive capacity figure; size it from actual backup requirements and rehearsal.
- Use reliable, local target volumes for ISO, backups, and status. A non-system volume in the same VM is not protection against loss of the whole VM or datastore.
- Pre-position exactly one approved target ISO in the chosen ISO folder, or resolve media selection explicitly before execution. Validate its origin, checksum, readability, matching image, and ability to be mounted.
- If D: is absent, small, an optical drive, or occupied by another purpose, choose an appropriate local volume and explicitly set `-IsoFolder`, `-BackupRoot`, and `-StatusJsonPath` as necessary. The backup root must not be on the system drive.
- Confirm free space for the local System State backup and `WindowsImageBackup` structure on the backup volume. No UNC backup or mapped-drive variant is assumed by this baseline.
- Confirm authorized access to the target staging, persistent Scripts/Logs, status, backup, and automation-registry locations. Ensure unauthorized users cannot modify SYSTEM-executed scripts or read sensitive registry exports.
- Stage the authentic, approved Microsoft LGPO utility with the target files when portable Local Group Policy backup is required. Obtain it through the customer's approved software process; it is not downloaded automatically.

## 7. Recovery and Backup Gate

Complete this before launching the orchestrator, not while it is already preparing Setup:

1. Create a current application-consistent workload backup, including all required OS/data/boot disks, configuration, certificates/keys through secure procedures, and application-specific recovery material.
2. Confirm that backup data survives loss of the target VM/host/storage as required by policy. A local D: backup or VM checkpoint alone is not an independently verified recovery backup.
3. Verify restore access, credentials, compatible recovery tooling, destination capacity, and restore-test evidence. Record acceptable data loss (RPO), restore time (RTO), and who authorizes recovery.
4. Test console/out-of-band access and confirm the named recovery operator is available throughout the window.
5. Preinstall and validate Windows Server Backup if the standard System State step will be used. Installation is a customer-approved change; resolve any resulting restart before the upgrade. Do not leave the first feature-install test until the upgrade window.
6. Check VSS/backup writer health and perform an approved backup rehearsal with the intended target volume/account. Review the actual backup result and recovery suitability, not just the process completing.
7. Document application stop/start and rollback/recovery steps with decision times. Windows Setup's own rollback is best-effort, not a substitute for this plan.

**Current implementation caution:** individual registry, policy, service-snapshot, or System State backup failures can be non-blocking. Some health-check execution failures are also warnings. The default automation is not a fail-closed assurance that every prerequisite and every backup succeeded.

If customer policy requires all warnings/backup failures to stop Setup, or a human approval checkpoint immediately before Setup, the current release does not meet that requirement. That is a **NO-GO until an explicitly scoped code change is implemented and validated**, not something a launch flag can solve.

## 8. Safe Validation From the Actual Server A

These steps are performed by the customer operator on Server A, not on the developer's workstation. They do not run the target upgrade script. Use the same account, FQDN, transport, package, and policies planned for the actual test.

### 8.1 Name, Listener, and Two Independent Sessions

This example assumes approved HTTPS is already configured. Replace the target FQDN. If a different account is required, obtain its credential interactively and add it to the connection hashtable before the probes. Do not send secrets through chat.

```powershell
$target = 'ServerB.contoso.com'
$connection = @{ ComputerName = $target; UseSSL = $true; ErrorAction = 'Stop' }
# For an approved alternate account, run: $connection.Credential = Get-Credential
Resolve-DnsName -Name $target -ErrorAction Stop
Test-NetConnection -ComputerName $target -Port 5986
Test-WSMan @connection

$sessions = @()
try {
    $sessions += New-PSSession @connection
    $sessions += New-PSSession @connection
    Invoke-Command -Session $sessions[0] -ErrorAction Stop -ScriptBlock {
        Get-CimInstance Win32_OperatingSystem |
            Select-Object CSName, Caption, Version, BuildNumber, OSArchitecture, LastBootUpTime
        Get-Service WinRM, Schedule, Winmgmt, RpcSs, EventLog
        $PSVersionTable.PSVersion
        [Environment]::Is64BitProcess
        $ExecutionContext.SessionState.LanguageMode
    }
    Invoke-Command -Session $sessions[1] -ErrorAction Stop -ScriptBlock {
        Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' |
            Select-Object DeviceID, FileSystem, Size, FreeSpace
        Get-WindowsFeature AD-Domain-Services, Failover-Clustering, Windows-Server-Backup, RDS-RD-Server, RDS-Licensing |
            Select-Object Name, Installed
    }
} finally {
    if ($sessions.Count -gt 0) { Remove-PSSession -Session $sessions -ErrorAction SilentlyContinue }
}
```

Expected result: the FQDN resolves to the approved target, the chosen port is reachable, the probe and both sessions succeed, and returned information matches the inventory. A successful TCP test or `Test-WSMan` alone is insufficient. Investigate latency, authentication, or policy failures before proceeding. Status reads have bounded timeouts, so slow remoting may still produce cached readings even when eventual connection succeeds.

For an approved HTTP design, remove `UseSSL` from the hashtable and test port 5985. Do not use certificate bypass to make the HTTPS example pass. Workgroup/IP/custom-endpoint scenarios require their own validated configuration before continuing.

### 8.2 Reboot Gate

From the approved package's ServerA-Orchestrator directory, in the same session:

```powershell
$readinessParameters = @{ TargetComputer = $target; UseSSL = $true }
if ($connection.ContainsKey('Credential')) { $readinessParameters.Credential = $connection.Credential }
$readiness = .\Test-UpgradeReadiness.ps1 @readinessParameters
if ($readiness.RebootPending -ne $false) { throw 'STOP: pending-reboot readiness is blocked or unknown.' }
```

For HTTP, omit `UseSSL` here as well. The readiness helper does not perform the full 14 checks or certify media, backup, application compatibility, task permissions, or future remote availability. Repeat it immediately before execution and after any authorized servicing/restart.

### 8.3 Approved Smoke Tests and Rehearsal

Before the first real customer upgrade, obtain evidence for the remaining privileges and policies. These checks can create temporary artifacts and must be authorized separately:

- Copy the approved companion files through `Copy-Item -ToSession` into a separate temporary validation directory; compare SHA-256 hashes with the release package. Do not overwrite an active run's staging directory and do not invoke the copied upgrade script.
- Confirm the approved account can create/remove a harmless temporary registry value in an agreed test key and write/read the intended status/log/backup directories. Do not modify Windows Setup state or the active automation key to simulate progress.
- Register and run a separately named, harmless SYSTEM scheduled task using customer-approved test tooling, then remove it and its test artifacts. Confirm execution and output under SYSTEM, not only under the interactive administrator. Do not reuse an `OSUpgrade*` task name for the smoke test.
- Verify mounted-media readability and permitted PowerShell/CMD/native-tool execution under the intended security context. Keep Setup itself unstarted for these checks.
- Validate an independent WinRM file read while the first session is busy using a harmless customer-approved test workload. This is the topology used for kickoff plus status reporting.
- Verify EDR/application-control logs show no unexpected blocking. Authorize only the specific trusted components, locations, and actions required; do not disable security tooling wholesale.
- Run the complete approved release on the representative non-production target, including backup, reboot recovery, status retrieval, service validation, and evidence retention. Exercise a recovery procedure in an appropriate isolated environment.

Do not present these checks as a built-in feature of the readiness helper. They are customer/engineering qualification activities. If no representative rehearsal is possible, the remaining risk must be explicitly accepted; it cannot be described as validated first-attempt readiness.

## 9. Execution and Monitoring Plan

### Change-Window Controls

- All go/no-go items in Section 11 must be signed off before the main command.
- Freeze the release and final parameters. Confirm target identity independently with a second operator for business-critical changes.
- Complete application drain/quiesce and the final recovery point as agreed. Exclude competing patching, scheduled reboots, jobs, backups, and administrative changes for the window.
- Keep the standard Setup-managed restart mode for the first baseline test. Do not introduce `-UseControlledReboot` without separate qualification; it does not provide an interactive approval gate.
- Do not use `-SkipPatchCheckLab`, `-SkipSystemStateBackup`, or `-SkipCertificateCheck` for the standard customer acceptance run. Any exception needs a named owner and a tested alternative; skipping backup does not create one.
- Use `-DisableAutoCleanup` for the first evidence-gathering pilot if approved, with a named manual-retention/cleanup owner. Otherwise, verify the configured retention covers the review; default cleanup is scheduled 14 days after registration, not after completion.
- Select `-TimeoutMinutes` from rehearsal and the maintenance plan. Its default 180 minutes covers Server A's main monitoring loop, not the earlier assessment/backup. Expiration neither stops Setup nor authorizes a forced reboot.
- Enable an approved transcript/evidence collection on Server A. It supplements logs but may not preserve every progress-bar rendering.

### Authorized Launch Example

Only after approval, from ServerA-Orchestrator, using the validated HTTPS connection/account above. Replace the local target paths if the inventory uses different volumes. The timeout below is the default, not a promised duration.

```powershell
$upgradeParameters = @{
    TargetComputer = $target
    UseSSL = $true
    IsoFolder = 'D:\ISO'
    BackupRoot = 'D:\UpgradeBackup'
    StatusJsonPath = 'D:\upgrade_status.json'
    TimeoutMinutes = 180
    DisableAutoCleanup = $true
}
if ($connection.ContainsKey('Credential')) { $upgradeParameters.Credential = $connection.Credential }
.\Start-RemoteUpgradeOrchestrator.ps1 @upgradeParameters
```

For HTTP, omit `UseSSL` only if that is the already approved and validated transport. Do not switch authentication or transport for the first time at launch. Do not initiate a second run to investigate the first.

### Expected Behavior and Stop/Escalation Rules

- Assessment and backup can take significant time. Progress is based on steps processed, not an estimated clock. A paused number is not evidence of a hung process.
- The overall ranges are 0-10% assessment, 10-25% backup, 25-95% Setup, then validation to a terminal completion result. 95% can be retained through subsequent restarts.
- Safe OS/Windows PE does not expose the installed OS's normal WinRM/SMB/WMI/RDP services. The displayed phase can remain the last known Downlevel sample and then jump to completion. A historical phase/error table is not implemented in this release.
- Customer agreement to that visibility limit is a prerequisite. If continuous confirmed Safe OS/First Boot telemetry or an automatic phase-time table is a mandatory acceptance condition, this release is not ready for that condition.
- Use approved console access and native Setup logs to investigate unexpected behavior. Do not declare failure solely from a missed ping, an 8-second status timeout, a phase plateau, or an absent intermediate phase.
- Unexpected warnings require operator review, but the script may continue automatically. Do not assume there is time to intervene safely after a warning. This is why prerequisites and recovery must be verified beforehand.
- Once Setup starts, do not kill processes, remove tracking tasks, clear registry state, force reboot, or restore a checkpoint without the agreed recovery decision and responsible engineers. A remote console disconnect alone is not a cancellation.
- If monitoring stops, first inspect the target using the agreed diagnostic method. Re-running the main orchestrator is not guaranteed to be read-only or monitoring-only.

## 10. Acceptance, Evidence, and Recovery

Acceptance requires more than exit code 0 or a 100% bar:

1. Independently confirm the actual target OS version, build, edition, and installation type.
2. Review terminal status and all precheck, backup, and validation warnings. `CompletedWithWarnings` requires disposition; unavailable evidence is not successful validation.
3. Review service comparison and verify application transactions, dependencies, data access, and user connectivity with the application owner. Automated service checks are not full functional tests.
4. Confirm activation, security agents, encryption protection, monitoring, management connectivity, and scheduled workload/backup operation.
5. Confirm the resulting server remains recoverable and take the post-change backup required by policy.
6. Retain the approved release hash, final command/parameters excluding secrets, start/end timestamps, transcript, readiness result, precheck report, backup results, services comparison, target JSON, and Server A mirror/logs.
7. Preserve native Panther/rollback logs and SetupDiag results where available, before Windows or manual cleanup removes them. Error-level log entries do not automatically indicate a fatal upgrade failure.
8. Obtain application, platform, security, and change-owner sign-off, then clean up temporary smoke-test artifacts and the automation's artifacts under the approved retention procedure.

Default evidence locations are described in [CUSTOMER-OVERVIEW.md](CUSTOMER-OVERVIEW.md). In particular, preserve Server A's OrchestratorLogs folder and Server B's automation Logs folder, the per-run backup directory, and native Windows Setup evidence. Restrict access to SAM/SECURITY exports and other sensitive data.

When failure or rollback occurs, preserve evidence, verify the actual OS/workload state, and apply the pre-agreed recovery procedure. Windows Setup rollback, a script `Failed` status, and restoring a workload backup are different events; none should be assumed from another without verification.

## 11. Go/No-Go Sign-Off

Every applicable row must have evidence and an owner. Marking a row not applicable requires a reason. Stop on an unresolved blocker or requirement the current release cannot meet.

| Gate | Required Evidence | Owner | Result / Approval |
| --- | --- | --- | --- |
| Change and scope | Approved target, window, operators, supported upgrade path, and acceptance criteria | Change owner | Pending |
| Release | Fixed release/hash, reviewed package, passing offline checks, no mixed versions | Engineering | Pending |
| Representative rehearsal | Successful test under equivalent workload/policies, with findings resolved | Customer + engineering | Pending |
| Identity and remoting | Approved account, transport/certificate, actual authenticated sessions, concurrent status path | Identity / platform | Pending |
| Network | Required source-scoped routes and dependencies verified; optional ports not unnecessarily opened | Network / security | Pending |
| Endpoint security | Approved scripts/tools and SYSTEM task execution; no unexplained enforcement blocks | Security | Pending |
| Target and media | Correct target, compatible roles/apps/drivers, current trusted media, matching image | Platform / application | Pending |
| Health | Conclusive health results, patch review, resolved servicing, reboot gate clear | Platform | Pending |
| Storage and backup | Capacity, feature/writer health, successful backup evidence, secure storage | Storage / backup | Pending |
| Recovery | Independent restorable backup, console access tested, RTO/RPO and decision authority agreed | Recovery owner | Pending |
| Runtime permissions | File copy/hash, authorized write operations, SYSTEM smoke test, local-media access | Platform / engineering | Pending |
| Monitoring limits | Customer accepts cached phase/95% behavior and lack of automated historical table | Customer / change owner | Pending |
| Warning policy | Customer accepts current continuation behavior, or separately validated stricter code is approved | Customer / engineering | Pending |
| Launch review | Final parameters, no competing run, application drain, final backup, two-person target check | Execution lead | Pending |
| Evidence and closure | Retention, escalation contacts, application test plan, and cleanup owner | Operations | Pending |

## 12. Official Reference Material

- [Windows Server upgrade overview and restrictions](https://learn.microsoft.com/en-us/windows-server/get-started/install-upgrade-migrate)
- [Windows Server in-place upgrade](https://learn.microsoft.com/en-us/windows-server/get-started/upgrade-in-place)
- [PowerShell remoting requirements](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_remote_requirements?view=powershell-5.1)
- [PowerShell remoting security considerations](https://learn.microsoft.com/en-us/powershell/scripting/security/remoting/winrm-security?view=powershell-5.1)
- [Windows Setup logs](https://learn.microsoft.com/en-us/windows/deployment/upgrade/log-files)
- [SetupDiag](https://learn.microsoft.com/en-us/windows/deployment/upgrade/setupdiag)

These references describe the Windows components, not a certification of this custom automation. Environment-specific requirements and the agreed support process take precedence over generic examples.