# Windows Server In-Place Upgrade Automation

## Customer Overview and Operational Guide

| Document Information | Detail |
| --- | --- |
| Audience | Infrastructure owners, operations teams, application owners, and change approvers |
| Technical level | L100: introductory overview with an operational reference |
| Document version | 1.0 |
| Last updated | 28 September 2026 |
| Scope | Current implementation, operational responsibilities, and known monitoring limitations |

This document describes the custom automation provided for this engagement. It is intended to support planning, customer review, and controlled execution. It is not a Windows Server product specification, a guarantee of upgrade success, or a replacement for the customer's change, backup, security, and application acceptance processes. Confirm the approved script release before each execution.

## 1. Purpose and Scope

The solution coordinates an unattended, in-place Windows Server upgrade from a separate management server. An in-place upgrade is intended to retain applications, settings, and data while installing a newer operating system. Retention and application compatibility must still be validated for each workload.

The solution provides:

- Pre-upgrade assessment of selected operating system, media, and configuration requirements.
- Backup of selected system configuration, policies, and System State, subject to the options and limitations below.
- Unattended launch of Windows Setup and continued target-side execution across restarts.
- A remote progress display, a machine-readable status record, and diagnostic logs.
- Post-upgrade operating system and service checks, with a completion summary and warnings.
- Optional retention-based removal of the automation's target-side tracking artifacts.

The reported pilot completed a Windows Server 2019 to Windows Server 2022 upgrade with remote percentage reporting. This is evidence for that test environment, not certification of every server, upgrade path, or application.

### Boundaries

- The current workflow excludes domain controllers and servers identified by its failover-cluster check. This is a restriction of this automation, not a general statement about Windows Server upgrade support.
- Customer confirmation of a supported upgrade path, compatible applications, drivers, security agents, and licensing remains required.
- The solution does not provide full application testing, an enterprise backup platform, automatic Windows activation, or a guaranteed recovery mechanism.
- ServiceNow configuration and external change-management integrations are outside this document's scope.
- Continuous live visibility of every Windows Setup phase is not currently guaranteed. Section 5 explains this limitation.

## 2. Operating Model and Prerequisites

For the customer-environment qualification steps, network matrix, safe validation commands, and approval gates, use [CUSTOMER-READINESS-CHECKLIST.md](CUSTOMER-READINESS-CHECKLIST.md) alongside this overview. The checklist must be completed for the specific environment; it does not guarantee first-attempt success.

| Component | Responsibility |
| --- | --- |
| Server A: management server | Starts the workflow, copies the target files, reads status, displays progress, and retains a local status copy and logs. |
| Server B: upgrade target | Runs assessment and backup, launches Windows Setup, restarts as required, and publishes status whenever the installed operating system can run the monitoring scripts. |
| Windows Setup | Performs the operating system upgrade, including offline work and restarts; attempts rollback when applicable. |
| Customer operations and application teams | Approve the change, validate readiness and recovery, review warnings, test applications, and accept the outcome. |

Before starting, confirm the following:

1. An approved maintenance window covers assessment, backup, the upgrade, multiple restarts, and application validation. The target workload will be unavailable during parts of the upgrade.
2. A verified, recoverable backup and an agreed recovery procedure are available. The script's configuration and System State backups are not a substitute for a complete workload recovery plan.
3. Console or hypervisor access is available if remote management does not return. Assign an operator and an escalation contact for the change window.
4. Server A uses Windows PowerShell 5.1 with appropriate administrative access to Server B. Script execution must comply with organizational policy.
5. Name resolution, authentication, and PowerShell remoting (WinRM) are configured and tested from the actual Server A. The scripts do not configure listeners, firewall rules, trust, or certificates for the customer.
6. The approved Windows Server ISO is already available on Server B. The default location is `D:\ISO`; the orchestrator copies scripts, not the ISO.
7. The operating system edition, installation type, language, and supported upgrade path have been reviewed. A higher build number alone does not prove that an upgrade path is supported.
8. The system drive and backup drive have sufficient capacity. The default assessment threshold is 32 GB free on C:, but actual requirements depend on the workload and media. The backup location must be on a local drive other than C:.
9. Pending restarts and outstanding servicing operations have been resolved. Do not delete pending-reboot registry entries to bypass the checks.
10. Only one upgrade workflow is active for the target. Use an approved, versioned script package and retain its release identifier with the change record.

WinRM is required for normal staging and kickoff. Status reads can also use SMB administrative shares or Windows management interfaces where permitted, with WinRM JSON reading as a fallback. A blocked ping alone does not mean the target is unavailable.

## 3. End-to-End Workflow

```text
Prepare and authorize
        -> Connect and stage files
        -> Stage 1: Pre-upgrade assessment
        -> Stage 2: Backup
        -> Stage 3: Windows Setup and restarts
        -> Post-upgrade checks and customer acceptance
        -> Retain evidence and clean up
```

### 3.1 Connect and Stage Files

Server A checks that the required companion files are present and that WinRM is reachable. It copies six target-side files to the staging directory on Server B and starts the target workflow.

The workflow also inspects previous automation state. Depending on the state found, a repeat invocation may resume monitoring or start a fresh attempt after stale-state cleanup. A rerun is therefore not a guaranteed monitoring-only operation. Preserve evidence and confirm the target's condition before repeating a command.

### 3.2 Stage 1: Pre-Upgrade Assessment

The target runs 14 assessment steps and writes a report. The table summarizes the checks; it is not a complete application compatibility assessment.

| Check | Purpose and Current Behavior |
| --- | --- |
| Domain controller role | Blocks targets identified as domain controllers by this workflow. |
| Failover-cluster configuration | Blocks targets identified by the cluster feature/service check; use an appropriate separately planned cluster upgrade process. |
| System-drive space | Compares C: free space with `-MinFreeSpaceGB`. Insufficient space blocks progression. |
| Pending restart | Checks Windows servicing, Windows Update, and queued file rename/delete operations. Real pending operations block progression and are reported for investigation. |
| Component-store health | Uses the Windows DISM health scan. Detected corruption blocks progression; an inconclusive or unsuccessful scan can generate a warning requiring review. |
| System-file integrity | Uses Windows SFC to check protected system files. SFC can repair files during the check. Detected corruption, including repaired corruption, blocks progression until reviewed and rechecked; inconclusive results can generate warnings. |
| Installation media | Locates or mounts the ISO and checks that Windows Setup is available. |
| Edition and installation type | Checks for matching media, such as Datacenter and Desktop Experience. A detected mismatch blocks progression; inability to verify can generate a warning. |
| Newer target build | Checks that the selected media contains a newer operating system build. Same/older media blocks progression when detected; an unknown build requires manual review. |
| Windows activation | Records activation status. An activation concern is a warning, not automatic activation or a hard stop. |
| Patch currency | Queries update information and can fall back to the age of the latest installed hotfix. Detected non-currency blocks unless the lab-only override is used; assessment errors can be warnings. This is not a full compliance scan. |
| VMware Tools | On VMware targets, checks the configured minimum version and service state. A detected failure blocks progression. Not applicable on Hyper-V or physical targets. |
| Remote Desktop Services licensing | Where applicable, reviews Session Host license-server configuration and reports concerns for review. |
| Orphaned local profiles | Looks for profiles whose associated account no longer resolves. Detected findings block progression; any generated remediation guidance requires separate review and authorization. |

All assessment steps are normally allowed to finish so that the report can collect findings. A blocking result prevents progression to backup and Setup at the assessment gate; it does not necessarily stop the remaining checks immediately.

**A warning is not proof that a prerequisite passed.** Some checks continue when evidence is inconclusive. The full run is unattended and does not pause for approval between stages, so resolve known concerns before starting. Assessment is not entirely read-only: for example, it mounts media, writes logs/status, and SFC can repair system files.

### 3.3 Stage 2: Backup

The workflow creates a timestamped backup folder and processes these eight steps:

| Backup Step | Information Preserved |
| --- | --- |
| 1. Services baseline | Names, current states, and startup types for post-upgrade comparison. |
| 2. Registry hives | Selected SYSTEM, SOFTWARE, SAM, and SECURITY configuration data. |
| 3. Local Group Policy folders | A copy of the local policy folders; an empty folder can be legitimate when no local policy is configured. |
| 4. Portable Local Group Policy export | An additional export when the optional `LGPO.exe` utility is supplied. If absent, this step is skipped with a warning. |
| 5. Local security policy | A security-policy export using the Windows policy tool. |
| 6. Applied-policy report | A Group Policy results report for reference. |
| 7. RDS licensing database | A database copy where the Remote Desktop licensing role and database are applicable. |
| 8. System State | A Windows Server Backup System State backup, unless explicitly skipped. The Windows Server Backup feature can be installed automatically if missing. |

Configuration backups default to `D:\UpgradeBackup\<run timestamp>`. Windows Server Backup writes System State under `D:\WindowsImageBackup\<computer>` when D: is the selected backup drive; a location note is written in the per-run folder.

**Backup limitations:** some individual backup failures, including a System State failure, are non-blocking warnings. A critical failure of the overall backup stage can stop the workflow. Reaching the end of this stage does not prove that every backup exists or is restorable; skipped and attempted steps also count toward progress. Review the actual backup results and maintain an independently verified recovery backup before execution. System State is not a complete application-data or bare-metal backup.

### 3.4 Stage 3: Windows Setup and Restarts

The target records the source/target operating system details, places monitoring companions in a persistent location, and registers the scheduled tasks listed in Section 6. Windows Setup is then launched through a local task with elevated SYSTEM privileges, independently of the initial remote session.

Windows Setup performs the upgrade in its native phases:

| Setup Phase | Plain-Language Description |
| --- | --- |
| Downlevel | Preparation and upgrade work while the original Windows installation is running. |
| Safe OS | Offline installation work in the temporary Windows PE/Safe OS environment. |
| First Boot | Initial startup and configuration of the new Windows installation, including migration work. |
| Second Boot / OOBE | Further configuration and completion of Windows Setup. OOBE means the final setup/configuration experience. |

By default, Windows Setup controls its own restarts. The number and duration of restarts depend on the system; a specific restart count does not reliably identify a phase. Once Setup has been handed off, losing Server A's console does not itself cancel the target upgrade. Do not deliberately interrupt Setup or launch a competing run.

The current launch disables Setup Dynamic Update and requests telemetry to be disabled. It also permits dismissible compatibility warnings to be ignored; this does not bypass Windows Setup hard compatibility blocks. Customer-approved media currency and compatibility review are therefore important. These are implementation defaults, not configurable customer flags in the current orchestrator.

### 3.5 Post-Upgrade Checks and Completion

When completion is detected, the target checks the operating system build and edition, activation status, selected core services, and service changes against the pre-upgrade baseline. The report distinguishes attention items from routine service changes where its rules can do so. If the service baseline or comparison is unavailable, that limitation is recorded.

Server A presents the final status and performs an additional live build check when it can obtain the required information. The customer must still confirm the expected operating system, application function, connectivity, monitoring, security agents, backup operation, and licensing before closing the change.

| Outcome | Customer Interpretation |
| --- | --- |
| `InProgress` | The workflow has not reported a terminal outcome. Check status freshness as well as connectivity. |
| `Completed` | The target validation routine completed without recorded validation issues. This is not comprehensive workload or backup certification. |
| `CompletedWithWarnings` | The routine completed but reported issues requiring review, such as activation, edition/build, or service concerns. Do not treat this as automatic acceptance. |
| `Failed` | The workflow reported a blocking or execution failure, or detected Windows Setup rollback. Review the phase and diagnostic evidence; failure does not always mean rollback occurred. |
| Monitoring timeout | Server A stopped waiting after its configured monitoring window. The target might still be upgrading. Timeout is not a command to cancel Setup or proof of failure. |

Use the final status, warnings, actual operating system state, and logs together. Do not use a percentage or process exit code alone as customer acceptance evidence.

## 4. Understanding Progress

The progress bar describes workflow completion, not a prediction of time remaining.

| Workflow Segment | Overall Range | Basis |
| --- | --- | --- |
| Pre-upgrade assessment | 0-10% | Assessment steps processed. |
| Backup | 10-25% | Backup steps processed, including documented skips or non-blocking failures. |
| Windows Setup | 25-95% | Windows Setup's available progress counter, mapped to the workflow range. |
| Post-upgrade validation | 95-100% | Validation processing; 100% is published with the terminal completion result, which may include warnings. |

The display can also show the current stage's own percentage. For example, 50% of backup corresponds to approximately 17% overall. Long-running checks or System State backup can leave the number unchanged until that step finishes.

When no newer measurement is available, the last reported value is retained with freshness information where available. **95% does not mean that all offline work or restarts are finished.** The current Setup counter can reach that mapped value before those operations have completed.

Server A's regular monitoring interval defaults to 15 seconds; the target's scheduled status refresh is normally once per minute, with additional startup/event triggers. Connection attempts also take time. These intervals are not a promise that every phase will be observed or that data will be refreshed within 15 seconds.

## 5. Known Limitation: Live Phase Visibility During Restarts

> **Current limitation and disclosure:** Downlevel progress is tracked using available Windows Setup registry telemetry, process information, and operating system state while Windows is accessible. During Safe OS, the server boots into a temporary Windows PE environment and the normal installed operating system is offline. Continuous remote identification of Safe OS, First Boot, and every intermediate transition is not currently guaranteed.

In this offline environment:

- Normal Windows services used for management and file sharing, including the Server service (`LanmanServer`), Workstation service, and Netlogon, are not available in their usual installed-OS context. The usual management/networking service environment is not running.
- Existing SMB file-sharing sessions are disconnected. New connections typically cannot be established, and administrative shares such as C$, ADMIN$, IPC$, and the target's D$ share are not available through the normal installed Windows services.
- Remote PowerShell/WinRM, WMI/DCOM, RDP, and other normal management channels cannot be relied on during this period. The target-side Windows scheduled monitor cannot run normally inside Safe OS either.
- The system is performing offline upgrade work such as image servicing, migration, driver processing, and boot configuration, rather than serving normal application workloads.

Windows PE can support networking in some configurations. The limitation here is that this upgrade workflow does not establish a supported, continuously available management channel inside that temporary environment; it must not assume that normal services remain reachable.

As Windows starts again, connectivity and monitoring may resume only after some phases have already finished. Restart notifications and startup events provide useful evidence, but neither a restart event nor a brief outage proves the exact active Setup phase.

### What the Customer May See

- The percentage can pause during restarts while the last available value is retained.
- Downlevel may remain displayed as the last reported phase even though Windows has moved on. In the current implementation, the phase name can also remain stale when the target status record has not yet been refreshed.
- The remote display can move directly from Downlevel to completion without capturing Safe OS or First Boot individually.
- An unavailable management channel or a missing phase sample is not, by itself, evidence of upgrade failure. Conversely, a responding host alone is not proof that Setup is healthy or complete.

The phase display must therefore be interpreted alongside status timestamps, connectivity, final validation, and Windows Setup logs. Existing console explanations about the reason for a short outage are not conclusive evidence of the underlying phase. Automation logs record the observations the scripts made; they are not guaranteed to contain a complete Windows Setup phase history.

### Improvement Under Evaluation

The engineering team is evaluating how to use native Windows Setup evidence to improve phase visibility without presenting inferred information as confirmed fact. One option is a final, log-derived table showing recorded phase/subphase times, completion or rollback evidence, relevant operations, and error codes after the target becomes accessible.

**That automated historical phase/error table is not implemented in the current package.** Availability and accuracy will depend on the retained Windows Setup and rollback logs. If evidence is missing, a future report must identify the gap rather than invent a timestamp or failure stage. No guaranteed completion date or continuous Safe OS visibility is implied by this investigation.

For troubleshooting today, retain the native Setup logs and any available SetupDiag results. Error-level entries can occur even in a successful upgrade; they require correlation with the final outcome and surrounding records rather than automatic classification as a failed phase.

## 6. Scheduled Tasks on the Target

The following tasks are created on Server B, using the local SYSTEM account with elevated privileges. They do not run inside Server A's interactive session.

| Task | Trigger and Purpose | Operational Note |
| --- | --- | --- |
| `OSUpgradeSetupLaunch` | Starts Windows Setup locally when the upgrade is handed off. | Allows Setup to continue independently of the original WinRM session. |
| `OSUpgradePhaseMonitor` | Refreshes status every minute for the configured three-day repetition period, at Windows startup, and on selected startup events (12/6005). | Depends on Windows and Task Scheduler being available; it is not a WinPE agent. |
| `OSUpgradeRebootWatcher` | Responds to a Windows restart-initiation event (1074) and attempts to record the transition before shutdown. | Best-effort evidence only; it does not independently prove Safe OS entry or guarantee publication before shutdown. |
| `OSUpgradeAutoCleanup` | Runs once, normally 14 days after task registration, to invoke artifact cleanup. | Optional. It does not calculate a new 14-day period from successful completion. |

The setup/monitoring tasks are normally removed as terminal handling completes, with remaining automation tasks covered by cleanup. Do not manually remove tasks or alter their actions while a run is active.

## 7. Files, Reports, and Status Records

### 7.1 Files in the Solution Package

| File | Purpose |
| --- | --- |
| [ServerA-Orchestrator/Start-RemoteUpgradeOrchestrator.ps1](ServerA-Orchestrator/Start-RemoteUpgradeOrchestrator.ps1) | Main customer entry point on Server A: stage, start, monitor, and summarize. |
| [ServerA-Orchestrator/Test-UpgradeReadiness.ps1](ServerA-Orchestrator/Test-UpgradeReadiness.ps1) | Read-only check of pending-reboot flags, queued file operations, operating system details, and last boot time. It does not run the full assessment or launch an upgrade. |
| [ServerB-Target/Start-TargetUpgrade.ps1](ServerB-Target/Start-TargetUpgrade.ps1) | Runs the target assessment and backup, registers tasks, and starts Setup. |
| [ServerB-Target/OSUpgradeStatus.ps1](ServerB-Target/OSUpgradeStatus.ps1) | Shared helper for status, percentages, reboot evidence, and pending-reboot checks. |
| [ServerB-Target/Update-UpgradeStatus.ps1](ServerB-Target/Update-UpgradeStatus.ps1) | Updates target status and performs post-upgrade validation. |
| [ServerB-Target/setupcomplete.cmd](ServerB-Target/setupcomplete.cmd) | Windows Setup completion hook that triggers status/validation processing. |
| [ServerB-Target/setuprollback.cmd](ServerB-Target/setuprollback.cmd) | Windows Setup rollback hook that records a rollback signal and triggers status processing. |
| [ServerB-Target/Remove-UpgradeArtifacts.ps1](ServerB-Target/Remove-UpgradeArtifacts.ps1) | Removes target-side automation tracking artifacts when authorized. |
| Optional `LGPO.exe` | Customer-supplied Microsoft Local Group Policy utility for an additional portable policy backup. Place it with the target files when required. |
| [Tests/Test-ProgressAndReadiness.ps1](Tests/Test-ProgressAndReadiness.ps1) | Offline regression checks with mocked I/O and isolated startup checks. These do not certify a live upgrade. |

The six files in the ServerB-Target rows are staged together; keep the package versions consistent. Monitoring companions are then copied to the persistent Scripts directory. No customer editing of the shared helper or hook files is required for normal use.

### 7.2 Default Runtime Locations

These are locations on Server A or Server B, not folders on the development workstation. Some paths change when execution parameters are supplied.

| Location or Artifact | Server | Purpose |
| --- | --- | --- |
| `C:\Temp\OSUpgradeStaging` | B | Initial staging of target files. |
| `C:\ProgramData\OSUpgradeAutomation\Scripts` | B | Persistent monitoring/cleanup companions and Setup hooks. |
| `C:\ProgramData\OSUpgradeAutomation\Logs` | B | Master execution log (`OSUpgradeAutomation_<timestamp>.log`), status-monitor log (`Update-UpgradeStatus.log`), health-check output, and collected diagnostic output where available. |
| `D:\upgrade_status.json` | B | Latest machine-readable target status. JSON is a structured text format for operational tools and reporting. |
| `D:\UpgradeBackup\PreCheckReport_<timestamp>.log` | B | Assessment results and warnings. |
| `D:\UpgradeBackup\<timestamp>` | B | Per-run configuration backups, services baseline, post-upgrade service comparison, and backup result/location notes. |
| `OSUpgradeProgress.log` and `OSUpgradeStatusHistory.jsonl` in the per-run backup folder | B | Observed status/progress history after the backup folder is available. These are not a complete offline Setup timeline. |
| `D:\WindowsImageBackup\<computer>` | B | System State data managed by Windows Server Backup when using drive D:. |
| `postoobe.marker` and `rollback.marker` under the automation base folder | B | Signals written by the completion and rollback hooks. |
| `C:\ProgramData\OSUpgradeAutomation\OrchestratorLogs` | A | Orchestrator logs and the default `UpgradeStatus_<target>_Latest.json` local status mirror. |
| Windows Panther, Rollback, and SetupDiag log folders | B | Windows-generated troubleshooting evidence. Locations vary by phase, commonly under `C:\$WINDOWS.~BT\Sources`, `C:\Windows\Panther`, and `C:\Windows\Logs\SetupDiag`. |

### 7.3 Registry and JSON Information

The solution writes its own tracking values under `HKLM:\SOFTWARE\OSUpgradeAutomation` on Server B. The table groups the key operational fields; it is not an exhaustive registry schema. Operators should read these through the status output or approved diagnostics, not edit them to force a phase or result.

| Information Group | Representative Values | Meaning |
| --- | --- | --- |
| Run identification | `SchemaVersion`, `RunId`, `Sequence`, `StartTimeUtc`, `SetupLaunchTimeUtc` | Identifies the run and orders its status publications. |
| Workflow state | `Status`, `Phase`, `PhaseName`, `StageNumber`, `Stage` | Last reported outcome, named phase, and high-level stage. |
| Progress | `PercentComplete`, `OverallPercentComplete`, `StagePercentComplete` | Overall and stage progress. `PercentComplete` is the compatibility field for overall progress. |
| Source and freshness | `PercentSource`, `ProgressSource`, `ProgressFreshness`, `ProgressUpdatedAtUtc`, `StatusUpdatedAtUtc` | Where the measurement came from, when it was updated, and whether it is carried forward. |
| Restart evidence | `ExpectedDisconnect`, `RebootCount`, `LastObservedBootTimeUtc`, `BootEvidence` | Expected connectivity loss and observed restart evidence. This is not a guaranteed count of all WinPE restarts or an exact phase clock. |
| Operating system details | `SourceBuild`, `TargetBuild`, `SourceEditionId`, `SourceOSCaption`, `TargetOSCaption`, `PostUpgradeOSCaption` | Source, selected target, and observed post-upgrade system information. |
| Diagnostics | `Notes`, `SetupLogTail`, `SetupTelemetryPercent`, `SetupTelemetrySource`, `SetupFailureDetectedAtUtc` | Supporting messages, available Setup telemetry, and failure-detection information. |
| Backup and validation | `BackupFolder`, `SystemStateBackupPath`, `ServicesComparisonResult`, `ServicesComparisonReportPath`, `ServicesAttentionCount`, `LicenseRecommendation` | Evidence locations and validation findings to review. |
| Output configuration | `StatusJsonPath` | Location of the target status file used by the monitoring scripts. |

Phase identifiers are 1 for assessment, 2 for backup, 3 for Downlevel, 4 for a reported Safe OS/restart transition, 5 for First Boot, 6 for OOBE, 7 for validation/completion, and 99 for rollback/failure handling. Phase 4 can be a transition indication rather than direct observation inside Safe OS. Interpret all phases with the limitation in Section 5.

The scripts also read Windows-managed state, including `HKLM:\SYSTEM\Setup\mosetup\Volatile\SetupProgress`, the current Windows build, servicing/reboot flags, and boot information. These are separate from the automation-owned registry key and are not customer-editable controls for this solution.

Server A's JSON mirror retains the last target record and adds an `Observer` section with connectivity, last-read time, and cache age. A newly updated observer timestamp does not necessarily mean that the target phase or percentage is a new measurement.

## 8. Execution Parameters

Run the main orchestrator on Server A. The table lists its 22 solution-specific parameters; standard PowerShell common parameters are not listed. Switches are off unless supplied. Paths identified as target paths refer to Server B.

### 8.1 Target, Connection, and File Locations

| Parameter | Default | When to Use |
| --- | --- | --- |
| `-TargetComputer` | Required | Identifies the server to upgrade. Prefer a resolvable server name that matches the approved authentication/certificate configuration. |
| `-Credential` | Current user context | Supplies an authorized PowerShell credential object when another account is required. Do not embed passwords in scripts or command history. |
| `-UseSSL` | Off | Restricts WinRM to HTTPS/5986 with certificate validation. Without it, the orchestrator tries HTTP/5985, then HTTPS/5986. Use according to customer transport policy. |
| `-SkipCertificateCheck` | Off | Explicitly permits an HTTPS attempt without CA, name, and revocation validation. This weakens server identity validation; reserve for an approved test exception, not a production default. |
| `-SourceFilesPath` | Sibling `ServerB-Target` folder | Selects the directory on Server A containing the six target files. Use when the approved package layout is different. |
| `-RemoteStagingPath` | `C:\Temp\OSUpgradeStaging` | Changes the initial script staging directory on Server B. |
| `-IsoFolder` | `D:\ISO` | Selects the folder containing upgrade media on Server B. Use approved media and avoid ambiguous media selection. |
| `-BackupRoot` | `D:\UpgradeBackup` | Selects the target's configuration backup root, on a local drive other than C:. System State uses the root of that backup drive. |
| `-StatusJsonPath` | `D:\upgrade_status.json` | Changes the target status-file path. The monitor reads the configured location. |
| `-LocalStatusMirrorPath` | Per-target JSON in Server A's OrchestratorLogs folder | Changes where Server A writes its local status mirror. |

### 8.2 Assessment, Backup, and Restart Controls

| Parameter | Default | When to Use |
| --- | --- | --- |
| `-MinFreeSpaceGB` | `32` | Sets the C: free-space assessment threshold in GB. Do not lower it without validating actual upgrade requirements. |
| `-MaxPatchAgeDays` | `60` | Sets the permitted last-hotfix age for the fallback patch-age assessment. It does not install updates or prove patch compliance. |
| `-MinVMwareToolsVersion` | `12.0.0` | Sets the minimum VMware Tools version for VMware targets. Not applicable to Hyper-V or physical hardware. |
| `-SkipPatchCheckLab` | Off | Lab-only override that lets a detected patch-currency failure proceed as a warning. Do not use for production acceptance. It does not bypass pending restarts or other blockers. |
| `-SkipSystemStateBackup` | Off | Omits only the System State backup. Other backup steps still run and the skip is recorded. Use only with an approved alternative recovery plan; commonly useful for repeat lab validation. |
| `-UseControlledReboot` | Off | Requests that Setup not initiate the first restart automatically; the script waits for Setup processes to exit, waits 60 seconds, then requests a forced restart. This is an advanced mode, not an interactive approval checkpoint or maintenance-window scheduler. Validate separately before use. |

There is no current flag to skip the entire backup stage, bypass pending-reboot checks, or run the main orchestrator as a guaranteed monitoring-only command.

### 8.3 Monitoring and Retention

| Parameter | Default | When to Use |
| --- | --- | --- |
| `-PollIntervalSeconds` | `15` | Sets the regular Server A monitoring delay. Target refresh and connection timeouts still limit effective update frequency. |
| `-FastPollIntervalSeconds` | `5` | Sets the shorter delay in heartbeat/offline modes. A shorter interval cannot make Safe OS management services available. |
| `-TimeoutMinutes` | `180` | Limits Server A's main monitoring window after kickoff. It is not a timeout for the entire assessment/backup process and does not stop target Setup. |
| `-PhaseStallWarningMinutes` | `45` | Sets when a prolonged observed phase produces a warning. It is informational, not an automatic cancellation or proof of a stalled upgrade. |
| `-RetentionDays` | `14` | Schedules the one-time target artifact cleanup this many days after registration. Does not control backup retention or Server A log retention. |
| `-DisableAutoCleanup` | Off | Prevents automatic cleanup task registration. Use when evidence must remain until manual review and an authorized cleanup. |

### 8.4 Companion-Script Options

- The readiness checker supports `-TargetComputer`, `-Credential`, `-UseSSL`, and `-SkipCertificateCheck`. It defaults to HTTP; unlike the orchestrator, it does not automatically try HTTPS when HTTP fails. Use the connection options approved for the target.
- The target kickoff script accepts the applicable media, backup, assessment, retention, and restart parameters passed by the orchestrator. Normal customer execution should use Server A's orchestrator rather than invoke both scripts independently.
- The status updater's `-RebootInitiated` switch is for the internal scheduled-task workflow, not for manually declaring a phase.
- The cleanup script supports `-Force`, which bypasses its recorded non-terminal-state protection. Do not use it during an active or uncertain run; it removes evidence, not the underlying upgrade operation.

### 8.5 Typical Commands

Run these from the ServerA-Orchestrator directory in an approved elevated Windows PowerShell session. Examples use a placeholder target name and default target-side paths. Execution-policy approval and authentication must already be in place.

Read-only pending-reboot check:

```powershell
.\Test-UpgradeReadiness.ps1 -TargetComputer 'ServerB'
```

Standard upgrade, with backup enabled and no lab overrides:

```powershell
.\Start-RemoteUpgradeOrchestrator.ps1 -TargetComputer 'ServerB' -IsoFolder 'D:\ISO' -BackupRoot 'D:\UpgradeBackup'
```

HTTPS using an interactively obtained credential object:

```powershell
$credential = Get-Credential
.\Start-RemoteUpgradeOrchestrator.ps1 -TargetComputer 'ServerB.contoso.com' -UseSSL -Credential $credential
```

Lab-only repeat test, omitting System State only after recovery arrangements have been confirmed:

```powershell
.\Start-RemoteUpgradeOrchestrator.ps1 -TargetComputer 'LabServerB' -SkipPatchCheckLab -SkipSystemStateBackup
```

The readiness command is not a substitute for all prerequisites. Before an upgrade command, confirm the intended server, release, recovery plan, and absence of an active run. There is no approval pause before Setup in the standard workflow.

## 9. Security, Evidence Retention, and Cleanup

- Protect the staging and persistent script directories. Their contents are executed with administrative privileges; only approved administrators should be able to modify them.
- Registry exports, especially SAM and SECURITY, can contain sensitive account-related and security data. Logs can also contain server names, account identifiers, paths, and configuration. Restrict access, protect storage according to policy, and use approved channels for support transfers.
- Review the supplied scripts and agree the execution policy, WinRM authentication, certificate validation, and network permissions before deployment. Do not add broad firewall exceptions or disable certificate checks merely to make monitoring work.
- Capture the script release identifier, assessment report, backup results, final status JSON, relevant Server A/Server B logs, and application sign-off in the change record. Preserve native Windows Setup and rollback evidence before it is removed by other cleanup processes.
- Default target cleanup removes the automation's scheduled tasks, configured status JSON, automation registry key, and its ProgramData folder containing scripts, logs, and markers. It does not remove the Windows Server Backup feature installed during the run.
- The cleanup routine skips removal when it finds a recorded non-terminal state; the one-time cleanup task is then removed rather than repeatedly retried. Review any such case and arrange subsequent cleanup when safe. Do not rely on missing status as proof that no upgrade is active.
- Configuration/System State backups, Server A logs and status mirrors, initial staging, installation media, and Windows-managed upgrade artifacts are not covered by that target artifact deletion. Apply their own approved retention and cleanup procedures.

## 10. Acceptance and Support Checklist

Before closing the change:

1. Confirm the actual operating system edition and build match the approved target.
2. Review the final outcome, all assessment/backup/validation warnings, and any missing evidence. A successful overall result does not resolve every warning.
3. Confirm business applications, integrations, user access, security tooling, monitoring, and backup operations with their respective owners.
4. Confirm Windows activation and licensing through the customer's normal process.
5. Retain the change evidence and document follow-up actions before cleanup.

If the target does not return or reports failure, use the agreed escalation and recovery procedure. Capture current logs and console state before changing the system. Do not assume a timeout requires a forced reboot, and do not rerun the full orchestrator simply to query status.

For phase-level troubleshooting, Windows Setup logs and SetupDiag can supplement the automation's observations. A missing Safe OS or First Boot display sample should be investigated as a monitoring limitation separately from the actual upgrade outcome.

## 11. Further Information

- [Microsoft Learn: Windows upgrade log files and troubleshooting](https://learn.microsoft.com/en-us/windows/deployment/upgrade/log-files)
- [Microsoft Learn: SetupDiag](https://learn.microsoft.com/en-us/windows/deployment/upgrade/setupdiag)

The references explain Windows Setup diagnostics; they do not certify this custom automation or guarantee that every phase can be monitored remotely. Production use remains subject to customer approval, workload-specific validation, and the agreed support and recovery arrangements.