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
  `ExpectedDisconnect=1` without fabricating percentage progress. This marks
  a *pending/inferred* transition, not proof that WinPE has booted.
- Added a ten-minute dead-Setup detector. If Setup disappears without Event
  1074 reboot evidence, the run becomes terminal failure with the scheduled
  task result, last-observed time, and Panther log tails.
- Added explicit Panther terminal-error detection so a failed Downlevel attempt
  is reported as `Failed` instead of remaining indefinitely in Safe OS.

## How Each Phase Is Tracked

The three operator-facing **stages** are assessment (Stage 1), backup (Stage 2),
and Windows Setup execution (Stage 3). The numbered **phases** below are more
detailed; phases 3 through 7 and rollback phase 99 all belong to Stage 3.
`Start-TargetUpgrade.ps1` writes phases 1-3 during kickoff;
`Update-UpgradeStatus.ps1` owns the later observations. Both call the
`Set-Phase` helper in `OSUpgradeShared.ps1`, which publishes registry state at
`HKLM:\SOFTWARE\OSUpgradeAutomation` and JSON at `D:\upgrade_status.json`.
The run's `D:\UpgradeBackup\<run-folder>\OSUpgradeProgress.log` retains phase
history independently of temporary ProgramData tracking files.

| Phase | What establishes it on Server B | Percentage and limitation |
| --- | --- | --- |
| 1 - Pre-upgrade assessment | Starter records the outcome after each prerequisite check; `-PrecheckOnly` stops with `AssessmentPassed` before backup or Setup. | Completed checks / total checks, a measured task-count milestone; it does not establish an upgraded OS. |
| 2 - State and policy backup | Starter records each backup task, including the system-state backup in a normal run. | Completed tasks / total tasks, independent of Stage 1 and of Windows Setup's percentage. |
| 3 - Downlevel | Starter publishes `Launching setup.exe`, starts `OSUpgradeSetupLaunch` as SYSTEM, and confirms an engine process within 60 seconds. Later target polls require the source build, `$WINDOWS.~BT`, and a `setup`, `setuphost`, or `setupprep` process to confirm active Downlevel work. | Only `HKLM:\SYSTEM\Setup\mosetup\Volatile\SetupProgress` supplies a live Setup percentage. If absent, Stage 3 remains indeterminate until a real sample exists; backup's 100% is not a Setup percentage. |
| 4 - Safe OS / boot transition | Event-triggered `OSUpgradeRebootWatcher` calls the updater with `-RebootEvent` on User32 System Event ID 1074 while the run is in progress at phase 3 or 4. It sets `ExpectedDisconnect=1`. If Setup exits on the source build after that event, the updater continues to label the transition pending. | **Inferred, not measured in WinPE.** Target scripts cannot run there; timestamps and the last measured Stage 3 percentage pause. Connectivity loss alone cannot confirm Safe OS. A short phase may be skipped between polls. |
| 5 - First Boot | Target poll sees the live build equal `TargetBuild`, `HKLM:\SYSTEM\Setup\SystemSetupInProgress=1`, and no PostOOBE marker. | MoSetup `SetupProgress` if available; otherwise carry the last verified Stage 3 sample without inventing a new percent. |
| 6 - Second Boot / OOBE | Windows Setup's `/PostOOBE` invokes `setupcomplete.cmd`, which writes `postoobe.marker` and calls the updater. If the hook is absent, target build plus `SystemSetupInProgress=0` starts validation instead. | No independent OOBE counter; retain any last verified Setup sample. The hook alone does **not** declare success. |
| 7 - Post-upgrade validation | Target verifies its running build against `TargetBuild` derived from the selected ISO, then checks edition, activation, and pre/post services. Records `PostUpgradeBuild`, validation timestamp/result, and warnings. | Only validated completion sets 100% and `Completed` or `CompletedWithWarnings`. Build mismatch or unavailable build validation is `Failed`. Server A separately queries the live build before reporting success. |
| 99 - Rollback | Windows Setup's `/PostRollback` invokes `setuprollback.cmd`, creating `rollback.marker`; the updater prioritizes it and reports `Failed` / `Rolled Back`. | Retains the highest verified Setup-stage percentage for diagnosis; it is **not** a success percentage. |

Failure can also be reported before phase 99: on the source build, a known
terminal Panther error is reported immediately; if a previously seen Setup
process disappears **without** Event 1074, the updater waits ten minutes,
then records the last observation, `OSUpgradeSetupLaunch` task result, and
Panther log tails as a failure. A build differing from both `SourceBuild` and
`TargetBuild` is identified as unexpected and cannot pass validation. The
shared writer prevents in-progress phases moving backward or overwriting a
terminal outcome (apart from a later explicit rollback providing more detail).

## Status Delivery, Gaps, and Evidence

- The SYSTEM `OSUpgradePhaseMonitor` first passes a bounded pre-kickoff probe
  proving it can load the shared helpers and write registry state; otherwise
  Setup is not launched. After Setup is observed, the normal monitor starts
  after the starter lock is released, repeats every two minutes, and has a
  startup trigger for post-reboot recovery. The Setup hooks and Event 1074
  watcher provide additional event-driven updates. Monitor entry, lock
  deferrals, errors, and validation go to
  `C:\ProgramData\OSUpgradeAutomation\Logs\Update-UpgradeStatus.log`.
- The status writer uses a shared registry/JSON field list and publishes JSON
  through a temporary file followed by a move. Re-publishing JSON does not
  advance `LastUpdated`: that timestamp reflects a phase update, not a file
  copy. A terminal JSON publication failure keeps the target monitor available
  to retry instead of silently losing the outcome.
- Server A polls WinRM reachability and prefers authenticated WinRM registry
  status while available. It falls back to JSON over SMB (`D$`) and registry
  over CIM/DCOM; ping is only a reachability hint. It reports `ActivePolling`
  when WinRM answers, `Heartbeat` when another channel answers without WinRM,
  and `Offline` when none answer. During a total gap it retains the last
  confirmed phase as **unconfirmed**, never guesses that a reboot equals Safe
  OS. An Event 1074 `ExpectedDisconnect` annotates the gap but does not
  establish the exact phase.
- If an `InProgress` snapshot has not advanced for 150 seconds, Server A
  labels it `STALE`, not a current Downlevel reading. On initial connection,
  reconnect, or stale status it can request the **existing** monitor task to
  run (at most once per minute) and logs the live build, task state, and
  `LastTaskResult`; it does not launch another Setup or restart a running
  validation task. `-MonitorOnly` can request this refresh but never stages
  files, backs up, or starts an upgrade.
- Native progress is indeterminate until a verified Setup percentage exists.
  `[PROGRESS]` assessment/backup and `[TRACK]` Setup lines also appear in the
  Server A console/log for hosts where a native progress bar is not visible.
  `ProgressFreshness` and separate status/progress timestamps distinguish a
  measured or task-count milestone from a carried, cached, or terminal value.
  Progress is monotonic **within** a stage; Stage 2's 100% is not carried into
  Stage 3. Short phases can pass before the next observation even when the
  target's history contains the transition.

The previous WS2019 log returned the initial `Launching setup.exe` snapshot
from 04:25:41 after later reconnects: that proves the observed status was
frozen, **not** that the machine had reverted to Downlevel. The provided
orchestrator log cannot determine the original target monitor task exception;
inspect the target monitor log, scheduled-task `LastTaskResult`, live registry,
and Panther logs before deciding why publication stopped. That run's ISO
identified **Server 2025 / build 26100**, not Server 2022 / build 20348.
A lock screen or hostname is not evidence of which build is running.

Success requires Phase 7, `Completed` or `CompletedWithWarnings`, matching
`PostUpgradeBuild` and `TargetBuild`, a passed local validation result, and an
independent matching live `Win32_OperatingSystem.BuildNumber` read by Server A
after WinRM returns. Exit `0` also applies to *assessment-only* success, so
always check the terminal status. Exit `1` means failure; exit `2` means
monitoring ended without independently confirmed success. Resume with
`-MonitorOnly`, not another kickoff. Logs and operator commands are listed in
[README.md](README.md#commands-test-lab-upgrade-monitor-production) and the
detailed runbook in [CHANGE-TRACKING.md](CHANGE-TRACKING.md).

## Recovery and Upgrade Safety

- Made `wbadmin` system-state backup mandatory for a normal production run.
  Setup does not start when required recovery evidence is unavailable.
- Added `computerinfo`, `systeminfo`, `ipconfig`, service snapshots, policy
  exports, and durable progress history under `D:\UpgradeBackup`.
- Added `/Eula Accept` to unattended Windows Setup after a live lab run exposed
  error `0xC190010E` at the Downlevel EULA action.
- Launches Windows Setup from a separate SYSTEM scheduled task rather than a
  child of the WinRM session, so kickoff may return without stopping Setup.
- Added Setup process-start confirmation. Kickoff fails when the Setup engine is
  not observed within 60 seconds instead of assuming a slow launch.
- Hardened cleanup with mutex coordination, terminal-state checks, path
  validation, and reparse-point protection. Cleanup never deletes
  `D:\UpgradeBackup`.
- Kept orphaned-profile deletion as a separate reviewed operator action; the
  upgrade workflow never removes user profile data automatically.

## Operator Experience and Maintainability

- Added `-PrecheckOnly` to assess a server without backup or Setup launch, and
  `-MonitorOnly` to resume observation without staging or starting an upgrade;
  it may refresh the existing status-monitor task.
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
  checks, evidence locations, failure triage, and cleanup instructions;
  separated safe tests, disposable-lab shortcuts, monitoring, and production
  commands so lab skip switches are never mistaken for production defaults.

## Validation and Delivery

- Earlier blocking issues were reproduced in lab upgrade attempts. The
  latest frozen-status changes were validated in isolated tests, **not** yet
  by an end-to-end run of the updated scripts on the target VM.
- Added a non-operational regression suite covering monitoring, progress,
  orchestrator behavior, target status, and cleanup, plus syntax and optional
  PSScriptAnalyzer checks. See `Tests\Run-SafeTests.ps1` for the current suite.
- The safe tests do not start Setup, write the registry, create scheduled tasks,
  perform backup, or remove files from the development machine.
- Documented the architecture, implementation decisions, test runbook,
  production acceptance requirements, failure evidence, and operator workflow.

**Intended outcome:** the automation prevents duplicate or unsupported starts,
requires recovery and success evidence, reports observed progress without
guessing blind phases, diagnoses silent Setup failure and stale status, and can
be assessed or monitored without launching another upgrade. Confirm behavior
in the next checkpoint-based lab run before making production claims.
