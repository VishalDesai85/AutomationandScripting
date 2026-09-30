# OS Upgrade Automation - Contribution Summary

Converted the existing Windows Server upgrade scripts from a happy-path
solution into a fail-closed, testable workflow suitable for unattended
operation and integration with schedulers or ServiceNow.

## Reliability and Outcome Control

- Added fail-closed startup checks. An unreadable existing-run state is no
  longer treated as permission to stage or start another upgrade.
- Added global named mutexes across kickoff, status updates, and cleanup so
  concurrent target processes cannot corrupt shared state or overlap upgrades.
- Standardized process exit codes: `0` for verified success, `1` for failure,
  and `2` when monitoring ends without a confirmed terminal result.
- Required both the target's terminal status and an independent live OS-build
  query before reporting a successful upgrade.
- Added an upfront remote local-administrator check so permission problems are
  detected before staging or backup begins.

## Progress and Failure Detection

- Restricted live Windows Setup percentage to Microsoft's
  `HKLM:\SYSTEM\Setup\mosetup\Volatile\SetupProgress`. Removed
  ChildCompletion and Panther-regex percentages that could jump or regress.
- Added stage-scoped high-water enforcement. Progress cannot regress within a
  stage, and failure or rollback retains the highest verified Setup percentage
  instead of resetting to `0%`.
- Added `ProgressFreshness` values (`Live`, `Milestone`, `CarriedForward`, and
  `Terminal`) with separate `ProgressUpdatedAtUtc` and `StatusUpdatedAtUtc`
  timestamps. Missing telemetry carries the last verified sample without
  changing its original timestamp.
- Added Event 1074 handling that marks the Safe OS reboot transition and sets
  `ExpectedDisconnect=true` without fabricating percentage progress.
- Added a ten-minute dead-Setup detector. If Setup disappears without Event
  1074 reboot evidence, the run becomes terminal failure with the scheduled
  task result, last-observed time, and Panther log tails.
- Added explicit Panther terminal-error detection so a failed Downlevel attempt
  is reported as `Failed` instead of remaining indefinitely in Safe OS.

## Recovery and Upgrade Safety

- Made `wbadmin` system-state backup mandatory for a normal production run.
  Setup does not start when required recovery evidence is unavailable.
- Added `computerinfo`, `systeminfo`, `ipconfig`, service snapshots, policy
  exports, and durable progress history under `D:\UpgradeBackup`.
- Added `/Eula Accept` to unattended Windows Setup after a live lab run exposed
  error `0xC190010E` at the Downlevel EULA action.
- Added Setup process-start confirmation. Kickoff fails when the Setup engine is
  not observed within 60 seconds instead of assuming a slow launch.
- Hardened cleanup with mutex coordination, terminal-state checks, path
  validation, and reparse-point protection. Cleanup never deletes
  `D:\UpgradeBackup`.
- Kept orphaned-profile deletion as a separate reviewed operator action; the
  upgrade workflow never removes user profile data automatically.

## Operator Experience and Maintainability

- Added `-PrecheckOnly` to assess a server without backup or Setup launch, and
  `-MonitorOnly` to resume observation without staging or starting an upgrade.
- Added independent SMB/JSON, CIM/DCOM, and authenticated WinRM status paths so
  one blocked management channel does not make the monitor blind.
- Added clear phase, connectivity, progress-source, freshness, and staleness
  reporting, plus durable Server A and Server B logs for post-run evidence.
- Centralized duplicated registry/JSON status logic in `OSUpgradeShared.ps1` so
  target writers follow one status contract.
- Added guarded JSON publication, terminal-state retry behavior, cleanup audit
  logs, and resilient orchestrator logging so transient file-write failures do
  not terminate monitoring.
- Reworked the README into an operator guide with exact commands, success
  checks, evidence locations, failure triage, and cleanup instructions.

## Validation and Delivery

- Reproduced and corrected blocking issues through live Windows Server 2019 to
  Windows Server 2025 lab upgrades.
- Added a non-operational regression suite: all 9 PowerShell files parse, 72
  orchestrator assertions pass, and 107 target status/cleanup assertions pass.
- The safe tests do not start Setup, write the registry, create scheduled tasks,
  perform backup, or remove files from the development machine.
- Documented the architecture, implementation decisions, test runbook,
  production acceptance requirements, failure evidence, and operator workflow.

**Outcome:** the automation now prevents duplicate or unsupported starts,
requires recovery and success evidence, reports only observed progress, detects
silent Setup failure, survives management-channel interruptions, and can be
safely assessed or monitored without launching another upgrade.
