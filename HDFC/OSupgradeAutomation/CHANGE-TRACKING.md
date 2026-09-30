## Original-code comparison baseline

This document was checked against the original codebase supplied for reference:

- Repository:
  [moarshad_microsoft/osupgradetest](https://github.com/moarshad_microsoft/osupgradetest)
- Baseline commit:
  [`a458b9defb03ff007e4d4847f332494b72de3b09`](https://github.com/moarshad_microsoft/osupgradetest/commit/a458b9defb03ff007e4d4847f332494b72de3b09)
- Baseline commit time: `2026-09-26T13:56:35+05:30`
- Comparison method: a read-only clone plus PowerShell and
  `git diff --no-index`; no Python was used.

At the time of comparison, the current implementation differs from that
baseline across 13 code, hook, test and documentation files. The comparison
reported 2,535 inserted lines and 897 removed lines. Much of the apparent
removal from `Start-TargetUpgrade.ps1` and `Update-UpgradeStatus.ps1` is
intentional extraction into `OSUpgradeShared.ps1` and
`Remove-OrphanedProfiles.ps1`, not loss of behavior.

Key capabilities confirmed as **new relative to the supplied baseline**:

| Capability | Original baseline | Current implementation |
| --- | --- | --- |
| Assessment without backup/Setup (`-PrecheckOnly`) | Not present | Added |
| Read-only resume/observation (`-MonitorOnly`) | Not present | Added |
| Lab-only DISM ScanHealth skip (`-SkipDismScanHealthLab`) | Not present | Added |
| Lab-only SFC scan skip (`-SkipSfcScanNowLab`) | Not present | Added |
| Cross-process starter mutex | Not present | Added |
| Shared phase/status implementation | Duplicated in two scripts | Centralized in `OSUpgradeShared.ps1` |
| Authenticated WinRM status-payload fallback | Not present | Added |
| Explicit post-upgrade validation evidence fields | Not present | Added |
| Reparse-point cleanup defense | Not present | Added |
| Durable cleanup audit log | Not present | Added |
| Orchestrator-side remote administrator gate | Not present | Added |
| `computerinfo`, `systeminfo` and `ipconfig` backup evidence | Not present | Added |
| Required system-state backup failure gate | Failure was warning-only | Added for non-skip full runs |
| Setup process-start confirmation gate | Missing process was warning-only | Added |
| Isolated PowerShell regression suite | Not present | Added |

## Customer-facing explanation

### Short version

The automation still delivers the same outcome: remotely assess a Windows
Server, back up its recoverable state, start the in-place OS upgrade, survive
the required reboots, monitor progress and verify the final OS build.

The change is that uncertain conditions are no longer treated as success or as
permission to continue. The automation now stops safely when it cannot prove
that a new run is safe, prevents overlapping runs, requires independent evidence
before reporting success, provides assessment-only and monitoring-only modes,
captures better recovery evidence and makes cleanup more defensive.

### Why this work was required

The earlier implementation was functionally capable but had several
production-readiness risks:

- Some failures returned success-shaped results or allowed processing to
  continue based on an assumption.
- A temporary loss of monitoring data could be described as a confirmed OS
  phase even though the phase was not observable.
- Repeated failure of the final build query could eventually be accepted as a
  successful upgrade.
- Two target-side scripts contained separate copies of the same status-writing
  logic, allowing the copies to drift.
- Simultaneous starter, status and cleanup processes could modify the same
  state.
- There was no safe way to exercise assessment or monitoring separately from
  the full upgrade.
- Cleanup and profile remediation needed stronger protection against deleting
  the wrong data.

The principle applied throughout the changes is:

> If the automation cannot prove that an operation is safe or successful, it
> must report the uncertainty and stop or continue monitoring; it must not
> guess.

### What remains unchanged

- Windows Setup remains the component that performs the in-place upgrade.
- A normal invocation still runs assessment, backup, Setup kickoff, reboot
  monitoring and post-upgrade validation in that order.
- The existing phase numbers and the Server A/Server B architecture remain.
- The durable backup under `D:\UpgradeBackup` is not removed by artifact
  cleanup.
- Orphaned-profile data is never removed automatically by the upgrade
  pre-check.
- The two Windows Setup hooks retain their mandatory exact names:
  `setupcomplete.cmd` and `setuprollback.cmd`.
- No firewall, TrustedHosts, certificate, Windows Update or domain policy is
  changed automatically to make a failed connection work.
- Lab override switches remain explicit and are not enabled by default.

## Implemented changes

| Surface | Previous problem | Change and reason |
| --- | --- | --- |
| Orchestrator startup | An inaccessible existing-state query was treated as no existing attempt. | Fail closed before staging/kickoff when the state query fails. Absence is distinguished from an unreadable registry key. |
| Orchestrator exit code | A failed precheck/kickoff returned normally, allowing a scheduler to report success. | Exit 1 for failed kickoff; successful assessment-only exits 0. |
| Assessment completion logging | `-PrecheckOnly` published `AssessmentPassed`, then called target `Write-Log` with unsupported level `SUCCESS`, turning a passed assessment into a wrapper failure. | Use the target logger's supported `PASS` level and regression-check every literal target log level against its `ValidateSet`. |
| Retry credential hint | A wrapped credential type could miss the PSCredential type check and render `-Credential ` with no value in the suggested retry command. | Render credentials by parameter name and always emit `-Credential $cred` plus the `Get-Credential` hint. |
| Failure guidance accuracy | The banner said no ISO was mounted even though assessment can mount one, and pointed to a nonexistent `UpgradeBackup\Logs` report folder. | State the real assessment side effects and derive the report glob from `BackupRoot`, matching the target writer. |
| Assessment console teardown | ConsoleHost could redraw stale `Write-Progress`/remote-output fragments after the prompt even though the assessment job had completed. | Give Stage 1/2 progress a stable ID, clear it again after the final remote stream drain and move terminal output to a clean line. |
| Independent build verification | HTTP with explicit credentials passed an unsupported `Credential` argument to `Get-CimInstance`. Eight failed confirmations then silently authorized success. Missing target builds also authorized success. | Always authenticate through a disposable CIM session for HTTP/HTTPS. Require a matching live build; unavailable/missing/mismatched evidence keeps monitoring until timeout (exit 2), not success. |
| Status channels | WinRM could be healthy while blocked SMB/DCOM left the monitor permanently blind. Missing registry values could look like a valid snapshot. | Add a bounded authenticated WinRM status read, reject incomplete JSON/registry snapshots and clean up jobs/sessions. No firewall or authentication policy is changed. |
| Progress | A monotonic percentage clamp crossed stage boundaries, e.g. assessment 100% masked backup 0%. | Clamp only within the same stage; clamp displayed assessment percentage to valid bounds. |
| Progress provenance and freshness | Windows Setup percentages could come from undocumented ChildCompletion or Panther regex values; status writes and real progress samples shared one timestamp; terminal failure reset progress to 0%. | Stage 3 now accepts only Microsoft MoSetup `SetupProgress`. Added `ProgressFreshness`, `ProgressUpdatedAtUtc`, `StatusUpdatedAtUtc` and stage high-water fields. Missing telemetry and terminal failure retain the highest verified stage value and its original progress timestamp. |
| Reporting | Brief network outages and skipped polls were presented as proof of particular reboot behavior or a gap-free timeline. | Report only observed facts and direct operators to available target/Setup logs. A prior completion banner no longer asserts a verified current OS before the live check. |
| Parameter validation | Zero/negative timing and malformed status paths failed late or produced invalid monitoring behavior. | Validate intervals, retention, patch age, disk threshold, target name and drive-qualified staging/status paths before operational work. An explicitly invalid source folder is no longer silently replaced with another folder. |
| Read-only monitoring | Restarting the orchestrator could stage and start an upgrade when the operator only intended to inspect status. | Add `-MonitorOnly`; never stage/kick off in that mode. It can start while WinRM is unavailable. Use `-UseSSL` for an offline HTTPS-only target. |
| Remote permissions gate | Initiating connection without verifying administrator membership could fail mid-process. | Added explicit administrative role verification (`WindowsBuiltInRole::Administrator`) on the remote target before staging or kickoff. |
| Target concurrency & mutex | Concurrent runs on Server B or between orchestrator and cleanup could stomp over state. | Enforced global named mutex `Global\OSUpgradeAutomation.StartTargetUpgrade` in `Start-TargetUpgrade.ps1` with graceful failure; coordinated with status and cleanup mutexes. |
| Assessment-only mode | No safe way to run end-to-end assessment without taking full backups and launching setup.exe. | Added `-PrecheckOnly` switch to both `Start-RemoteUpgradeOrchestrator.ps1` and `Start-TargetUpgrade.ps1` that runs all pre-checks, writes reports, and exits cleanly with exit code 0 on pass. |
| Faster disposable-lab assessment | DISM ScanHealth and SFC always ran and could make repeated functional checks slow. | Added independent `-SkipDismScanHealthLab` and `-SkipSfcScanNowLab` switches. Each skipped check remains counted as WARN and explicitly unverified. They may be combined for disposable testing but are forbidden for production acceptance. |
| Host diagnostics capture | ImprovementsRequired.md required capturing computerinfo, systeminfo, and ipconfig into backup directory. | Added capture of `computerinfo.txt`, `systeminfo.txt`, and `ipconfig.txt` to both `$backupFolder` and `$BackupRoot` during backup phase. |
| Required system-state backup | `wbadmin` failure was warning-only, so Setup could start without the required recovery evidence. | A non-skipped full run now fails the backup stage if the feature requires a reboot or `wbadmin` fails. The explicit lab-only skip remains available. |
| Setup kickoff verification | Not observing the Setup process within 60 seconds produced only a warning and returned a successful kickoff result. | Read the scheduled-task result and fail kickoff when no Setup process is observed; do not assume a slow start. |
| Status helper unification | Duplicated functions in `Start-TargetUpgrade.ps1` and `Update-UpgradeStatus.ps1` caused drift. | Unified in `OSUpgradeShared.ps1` dot-sourced by both scripts. Added to required files list in Orchestrator. |
| Cleanup safeguards | Cleanup could delete files while starter/status was running or follow symbolic links. | Guarded with mutexes, added reparse point and path format assertions (`Assert-NoUpgradeReparsePoint`, `Assert-UpgradeCleanupPath`). |
| Windows Setup EULA acceptance | `setup.exe` was launched unattended without `/Eula Accept`, so Setup self-terminated during Downlevel with `0xC190010E` ("User did not accept EULA at downlevel OS") before reaching Safe OS. | Pass `/Eula Accept` in the Setup argument list. Confirmed against a real WS2019 run that failed at this exact point. |
| Downlevel Setup failure detection | With `$WINDOWS.~BT` present and no Setup process, the monitor unconditionally published Phase 4 "Safe OS Phase". A dead attempt was therefore reported as a healthy blind window indefinitely. | Read `setuperr.log` first; on a terminal Setup signature publish `Status=Failed` with the captured log line. The Safe OS branch now applies only when no failure evidence exists. |
| Bounded dead-Setup detection | Setup could disappear without a Panther terminal signature and still be inferred as Safe OS forever. | Event 1074 sets `ExpectedDisconnect=true` without fabricating percentage. Without that evidence, ten continuous minutes of Setup absence publishes terminal failure with scheduled-task result, last-observed time and Panther log tails. |
| Live build verification transport | `Get-RemoteOperatingSystem` called `New-CimSessionOption` with no protocol, so the mandatory `-Protocol` parameter prompted interactively and blocked the final success check. | Specify `Protocol = "Wsman"` explicitly, matching the DCOM reader that already passed `-Protocol Dcom`. |
| Orchestrator log durability | Server A appended with bare `Add-Content` under `$ErrorActionPreference='Stop'`, so a transient file lock (AV scan, full disk) would terminate the orchestrator mid-upgrade. The equivalent hazard had already been fixed on the target side. | Route every write through a guarded `Add-LogFileLine` using `AppendAllText`, reporting a write failure once and continuing. Losing a log line must never stop monitoring. |
| Target output lost from the log | The target's `Write-Host`/`Write-Warning` records reached Server A's console through `Receive-Job` but were never written to the orchestrator log file. All Stage 1/2 detail was therefore console-only and lost when the window closed. | Persist those records to the log file from the job's stream collections, using a per-stream index cursor so each is written exactly once. |
| No progress trail in the log | The progress bar existed only on screen, so the log contained phase transitions but no percentage, provenance or staleness timeline. | Append a `[TRACK]` line on every percentage/phase change and at least once a minute, carrying stage, phase, percent, provenance, status, mode, source and target-status age. |
| Tracker readability and staleness | One dense line mixed stage, percent, phase, status and source, and nothing showed whether the number was still fresh. | Split across the Write-Progress activity/status/operation fields, add a done/active/pending lifecycle strip for all seven phases, and surface how long the target's status has been unchanged. |

## Lab run findings and fixes (2026-09-28)

These three defects were found during live WS2019 to Server 2025 runs, not by
inspection. Each is recorded with the observed evidence.

### 1. Setup exited at the EULA action

Observed in `C:\$WINDOWS.~BT\Sources\Panther\setuperr.log`:

```text
2026-09-28 13:24:23, Error  MOUPG  User did not accept EULA at downlevel OS.
2026-09-28 13:24:23, Error  MOUPG  CSetupManager::Execute(345): Result = 0xC190010E
```

- Previously: the launch arguments were `/Auto Upgrade /Quiet /DynamicUpdate
  Disable /Telemetry Disable /Compat IgnoreWarning` plus the hooks. Setup ran
  the EULA action, found no acceptance, and terminated roughly 2.5 minutes
  after launch. No reboot and no Safe OS transition ever occurred.
- Now: `/Eula Accept` is included, so the unattended run satisfies the same
  action interactively-installed media satisfies through the UI.

The `0x80072EE7` OneSettings/`hwreqchk` errors in the same log were present but
are **not** the terminating cause; they reflect restricted outbound name
resolution and are already mitigated by `/Telemetry Disable`.

### 2. A dead attempt was reported as Safe OS for hours

- Previously: `Update-UpgradeStatus.ps1` reached the branch
  `$btPresent -and -not $setupProc` and always published Phase 4 with the note
  "process not resident - machine likely rebooting into Safe OS/WinPE". That
  inference is correct for a genuine reboot, but it was applied without
  checking whether Setup had instead **failed**. In the observed run the status
  froze at `Phase 4 / InProgress / 8%` from `13:59:49` onward while the server
  was in fact idle and still on build 17763.
- Now: the same branch first reads the tail of `setuperr.log` and matches
  terminal Setup signatures. When one is found it publishes
  `Phase 4 / "Windows Setup Failed" / Status=Failed / 0%` with the offending
  log line in `Notes`. Because `Failed` is terminal, Server A stops monitoring
  and prints the failure banner instead of waiting out the timeout.
- Unchanged: when there is no failure evidence, the Safe OS inference behaves
  exactly as before. The blind window is still honestly reported as inferred.

### 3. Final build check prompted for a CIM protocol

- Previously: `Get-RemoteOperatingSystem` built `$optionArgs = @{}` and called
  `New-CimSessionOption @optionArgs`. With no protocol supplied, PowerShell
  prompted `Supply values for the following parameters: Protocol:` and the
  monitoring loop stalled at the last step of an otherwise successful upgrade.
  The HTTPS paths were unaffected only because they added `UseSsl`.
- Now: the hashtable is seeded with `Protocol = "Wsman"`, so the WSMan session
  is created non-interactively for HTTP, HTTPS and HTTPS-skip-certificate.

### Verification

`Tests\Run-SafeTests.ps1` passes after these changes: 9 files parse, 67
orchestrator assertions and 88 status assertions succeed. No test executes an
upgrade, registry write or cleanup.

## Logging and tracker hardening (2026-09-29)

### Measured stream behaviour behind the lossless-log fix

The first attempt at capturing the target's output merged the warning and
information streams into the success stream
(`Receive-Job ... 3>&1 6>&1`) and re-rendered the records. Executing it against
a real background job disproved the assumption behind it. Measured results:

| Approach | Console | Captured |
| --- | --- | --- |
| `Receive-Job` | info + warning printed | result object only |
| `Receive-Job 3>&1 6>&1` | info + warning **still printed** | information records only |
| `Receive-Job *>&1` | info + warning **still printed** | information records only |

Two conclusions, both contrary to the initial design:

1. Redirection does **not** suppress `Receive-Job`'s own host rendering, so
   re-printing captured records doubled every line on screen.
2. `WarningRecord` is never delivered to the success stream, so warnings were
   still lost.

A second measurement showed `Receive-Job` does **not** drain
`$job.ChildJobs[].Information`/`.Warning`/`.Error`; those collections grow for
the life of the job. Reading them naively re-logged the entire history on every
poll.

The shipped implementation therefore reads those collections directly with a
per-stream index cursor and writes file-only, leaving console rendering to
`Receive-Job` exactly as before. Verified end to end against a real job:
every line appears once on the console and once in the file, warnings
included, and the result object still passes through untouched.

### Tracker display

The monitoring bar now separates its fields and states the lifecycle
explicitly:

```text
OS upgrade on WS2019   |   Stage 3/3: Windows Setup Execution   |   ONLINE / Active Polling
[42% Measured]  Downlevel Phase   (Status=InProgress, src:File, target status unchanged for 8s)
Lifecycle: [x] 1 Assess   [x] 2 Backup   >> 3 Downlevel   [ ] 4 SafeOS   [ ] 5 FirstBoot   [ ] 6 OOBE   [ ] 7 Validate
```

The lifecycle strip is rendered only from a confirmed numeric phase; during a
connectivity gap it reports that it is awaiting a confirmed reading rather than
advancing. This is the same rule the phase-change log already follows.

Staleness is measured by watching when the target's `LastUpdated` **value**
changes, timed on Server A's clock. Subtracting the target's timestamp from
Server A's wall clock would report ordinary clock skew as staleness, and the
two values are not even on the same basis - status `LastUpdated` is
target-local while validation timestamps are UTC.

### Not implemented

The hash-chained evidence ledger, weighted cross-phase percentage model and
retroactive Safe OS reconstruction discussed separately are **not** part of
this change set.

### Resolved: the 53-minute reporting gap was console QuickEdit

On 2026-09-28 the target published a terminal failure at `23:06:49` while
Server A only printed it at `23:59:25`. This was first recorded as an
undiagnosed orchestrator defect. It is neither an orchestrator nor a target
defect.

Windows `conhost` **QuickEdit Mode** is enabled by default. Clicking anywhere
in the console window - or accidentally selecting text - puts the console into
mark/selection mode, which **suspends the running process** at its next write
to stdout. The process stays frozen until Enter or Esc is pressed. The operator
confirmed the matching symptom: the run appeared hung and resumed correctly the
moment Enter was pressed.

Consequences worth knowing:

- The upgrade on Server B is never affected. It is driven by scheduled tasks
  and Windows Setup, both independent of Server A's console.
- Only Server A's display and logging are paused, so timestamps after a pause
  reflect when the console resumed, not when the event occurred. The target's
  `LastUpdated` remains the accurate time.

To remove the hazard for unattended runs, disable QuickEdit for the console
host used by the operator:

```powershell
# 0x0040 = ENABLE_EXTENDED_FLAGS without ENABLE_QUICK_EDIT_MODE (0x0040 only).
Set-ItemProperty -Path 'HKCU:\Console' -Name QuickEdit -Value 0 -Type DWord
```

Open a new console afterwards. Windows Terminal is not affected in the same
way; the classic `conhost` window is.

### Post-upgrade validation is no longer a silent window

- Previously: once the `/PostOOBE` hook fired, the monitor published Phase 6
  and then called `Invoke-PostUpgradeValidation`, which wrote nothing until it
  finished. Activation lookup via `SoftwareLicensingProduct` and the full
  services comparison can take minutes. In the 2026-09-29 run the target's
  `LastUpdated` stopped at `01:16:22` while Server A reported at `01:19:06`.
  The upgrade was already complete and the server was usable, but the operator
  had no way to tell validation from a hang.
- Now: validation publishes `Phase 7 / "Post-Upgrade Validation" /
  Status=InProgress` before it starts, stating that Windows Setup has finished
  and the system is no longer being changed, and republishes before the
  services comparison. Server A's existing phase-change logging surfaces both
  without any orchestrator change.
- Re-entry safety: the two OOBE call-site guards changed from `$lastPhase -lt 7`
  to `-le 7`, so validation interrupted by a reboot is retried rather than
  stranded at Phase 7 `InProgress`. The terminal-status check at the top of
  Main still prevents re-running validation on a finished run.

## Detailed developer handover

### `Start-RemoteUpgradeOrchestrator.ps1` - Server A

Changes:

- Added validation for target names, local drive-qualified paths, retention,
  free-space thresholds, polling intervals and timeout values.
- Made an explicitly supplied invalid source folder fail instead of silently
  switching to another folder.
- Added a remote local-administrator membership check before files are staged.
- Changed existing-attempt detection to fail closed when state cannot be read.
- Included the target starter mutex in existing-attempt detection, covering
  assessment and backup time before `setup.exe` exists.
- Added `OSUpgradeShared.ps1` to the required deployment files.
- Added `Remove-OrphanedProfiles.ps1` as an optional remediation companion.
- Added a bounded authenticated WinRM status-data channel after the SMB JSON
  and CIM/DCOM channels.
- Rejected empty or incomplete JSON/registry status objects.
- Changed synthetic fallback states to `Status=Unknown`; ping or WinRM
  reachability alone is no longer presented as upgrade progress.
- Corrected the progress high-water mark so it applies only within one stage.
- Added `-PrecheckOnly`, `-MonitorOnly` and pass-through for
  `-SkipDismScanHealthLab` and `-SkipSfcScanNowLab`.
- Changed failed assessment/kickoff to exit code 1 instead of returning from
  the script with a success process code.
- Removed the fallback that accepted completion after repeated final CIM
  failures. A final matching live build is now mandatory.
- Reworded outage and skipped-phase messages so they distinguish observation
  from inference.
- Specifies `Protocol = "Wsman"` when building the live build-verification CIM
  session, so the final success check never prompts for a mandatory parameter.
- Routes all log writes through a guarded append so a transient file-lock or
  disk-full condition can no longer terminate an in-flight upgrade monitor.
- Persists the target's replayed output to the orchestrator log file via a
  per-stream index cursor, leaving console rendering to `Receive-Job`.
- Appends a `[TRACK]` progress line on change and at least once a minute, so
  the log carries a percentage/provenance/staleness timeline.
- Renders the tracker across separate activity/status/operation fields with a
  seven-phase lifecycle strip and a target-status staleness indicator.

Why:

Server A is the control and reporting surface used by operators or an upstream
automation platform. Its output and exit code must be reliable enough to drive
a change ticket or job result. A reachable server is not necessarily a
successful upgrade, and unreadable state is not proof that no upgrade is
running.

### `Start-TargetUpgrade.ps1` - Server B

Changes:

- Added the global starter mutex
  `Global\OSUpgradeAutomation.StartTargetUpgrade`.
- Added `-PrecheckOnly`; it runs the normal checks and writes the report but
  returns before backup, scheduled-task registration and Setup launch.
- Added `-SkipDismScanHealthLab`; the skip branch does not invoke `Dism.exe`,
  records the existing DISM check as WARN and states that component-store
  health was not validated. The normal path still runs ScanHealth.
- Added `-SkipSfcScanNowLab`; the skip branch does not invoke `sfc.exe` or
  analyze CBS.log, records the existing SFC check as WARN and states that
  protected system-file integrity was not validated. The normal path still
  runs `sfc /scannow`.
- Dot-sources the shared status helper rather than carrying a duplicate copy.
- Fails immediately if the required shared helper disappears or was not staged.
- Captures:
  - `computerinfo.txt`
  - `systeminfo.txt`
  - `ipconfig.txt`
- Stores the diagnostic files in the timestamped run folder and copies them to
  the backup root for easy access.
- Stages the shared status helper into the persistent ProgramData scripts
  folder before handing control to scheduled tasks and Windows Setup hooks.
- Replaced the embedded orphan-profile cleanup here-string with a separate,
  testable companion script.
- Added progress-count drift checks so a newly added or removed check cannot
  silently produce an incorrect customer-visible percentage.
- Makes the required system-state backup fail closed for a normal full run.
  If Windows Server Backup installation requires a reboot, the operator must
  reboot and rerun assessment/full kickoff.
- Treats an unobserved Setup process after the bounded launch window as a
  failed kickoff and includes the scheduled-task result in the diagnostic.
- Launches `setup.exe` with `/Eula Accept`. Without it an unattended run
  terminates during Downlevel with `0xC190010E` before any reboot.

Why:

Only one starter can safely own registry initialization, stale-state handling,
backup and Setup launch. Assessment-only testing must stop before the actions
that make a test slow or disruptive. Recovery evidence must be available in
one run folder, and shared runtime dependencies must be checked before Setup is
allowed to reboot the server.

### `OSUpgradeShared.ps1` - new required target component

Changes:

- Centralizes registry writes, registry reads, snapshot access, atomic JSON
  publication and phase/progress transitions.
- Publishes the same status fields regardless of whether the starter or status
  monitor performed the write.
- Retains the per-stage monotonic progress rule in one implementation.

Why:

The two previous copies had already diverged. A shared file eliminates an
entire category of maintenance bugs where one writer publishes different
fields or applies different progress rules from the other.

Deployment impact:

`OSUpgradeShared.ps1` is required. The orchestrator validates and stages it. A
manual deployment that omits it will fail before Setup starts rather than
running an upgrade with broken monitoring.

### `Update-UpgradeStatus.ps1` - Server B status engine

Changes:

- Coordinates with both the starter and status mutexes.
- Avoids reading partially initialized state while the starter owns the run.
- Does not recreate state after cleanup if the registry key no longer exists.
- Treats missing or mismatched target build as failed validation rather than
  successful completion.
- Requires post-upgrade evidence fields before a successful terminal state:
  `PostUpgradeBuild`, `PostUpgradeValidationTime` and
  `PostUpgradeValidationResult`.
- Retains terminal registry state if JSON publication fails and leaves the
  monitor available to retry publication.
- Separates verified completion from completion-with-warnings for activation
  or service findings.
- Inspects `setuperr.log` before inferring Safe OS from an absent Setup
  process, and publishes a terminal failure when Setup recorded one. The Safe
  OS inference is unchanged when no failure evidence exists.
- Publishes `Phase 7 "Post-Upgrade Validation" / InProgress` before running
  validation and again before the services comparison, so the multi-minute
  activation and service checks are visible rather than looking like a hang.
- Retries interrupted validation instead of stranding Phase 7 `InProgress`.

Why:

The target status engine is the source of truth. Terminal success must mean the
target build and validation actually passed, not merely that a marker file was
seen or Setup processes disappeared.

### `Remove-UpgradeArtifacts.ps1` - Server B cleanup

Changes:

- Coordinates with the starter and status mutexes before deleting anything.
- Refuses cleanup while the starter is active, including with `-Force`.
- Treats missing or unreadable status as unsafe instead of terminal.
- Limits `-Force` to overriding the terminal-status gate; it does not override
  unreadable state or path-safety checks.
- Validates that the status file is an absolute local `.json` path.
- Rejects reparse points before recursive deletion.
- Retains state needed for retry when cleanup fails partway through.
- Writes a durable cleanup log beside the run backup, with a Windows Temp
  fallback when the backup path is unavailable.

Why:

Cleanup is the most destructive part of the tracking lifecycle. It must not
race an active upgrade, follow a junction/symbolic link, delete a configured
non-status file or erase the evidence needed to diagnose its own failure.

### `setupcomplete.cmd` and `setuprollback.cmd` - Windows Setup hooks

Changes:

- Documented why the filenames must not be changed.
- Documented why each hook deliberately returns exit code 0 after invoking the
  status script.
- Clarified that the recurring monitor retries a transient reporting failure.

Why:

These hooks report an outcome that Windows Setup has already reached. Returning
a failure because status publication was momentarily unavailable would add a
misleading hook failure to an otherwise valid Setup result. The scheduled
monitor owns retries.

### `Remove-OrphanedProfiles.ps1` - new optional remediation component

Changes:

- Moved the generated 341-line script out of an embedded text block and into a
  normal PowerShell file.
- Keeps profile registry removal separate from optional profile-folder
  deletion.
- Requires a second explicit decision before deleting profile folders.
- Adds protected-path and profile-folder safety checks.
- Supports deliberate unattended use with `-Force`; folder removal still
  additionally requires `-IncludeProfileFolder`.

Why:

Profile cleanup can remove real user data. It must remain a reviewed operator
action, not an automatic pre-check side effect. A real script file can also be
parsed, linted, reviewed and regression-tested.

### Test and documentation components

- `Tests\Orchestrator.Tests.ps1`: 67 isolated assertions for parameter
  rejection, WinRM/CIM behavior, status fallbacks, build confirmation and
  stage-aware progress.
- `Tests\UpgradeStatus.Tests.ps1`: 88 isolated assertions for target status,
  terminal validation and cleanup safety.
- `Tests\Run-SafeTests.ps1`: parses all PowerShell files, runs all isolated
  tests and optionally runs PSScriptAnalyzer.
- `PROJECT-NOTES.md`: points future maintainers to this change record and
  supersedes older assumptions.

Why:

The tests exercise decision logic using in-memory PowerShell mocks. They do not
start Windows Setup, modify the registry, create tasks, delete files or require
a target VM. This provides a fast regression gate while keeping destructive
integration testing separate.

## End-to-end behavior after the changes

For a normal full run:

1. Server A validates parameters and verifies all required local files.
2. Ping is used as an advisory signal; a resolved WinRM transport is the
   control channel.
3. Server A verifies the remote execution identity has administrator rights.
4. Existing registry state, Setup activity and the starter mutex are checked.
5. If state is uncertain or another starter is active, no new kickoff occurs.
6. Required and available optional files are staged.
7. Server B takes the starter mutex and runs all pre-checks.
8. A failed check publishes failure and returns exit code 1.
9. `-PrecheckOnly` publishes the assessment result and stops here.
10. A full run creates the backup and diagnostic evidence.
11. Persistent scripts, monitor, reboot watcher, cleanup task and Setup hooks
    are registered.
12. Setup is launched through its decoupled scheduled task.
13. The target monitor and Setup hooks update the shared state through the
    status mutex.
14. Server A reads status through SMB, CIM/DCOM or authenticated WinRM and
    carries cached values only when clearly labelled as cached.
15. Success is returned only after target validation and an independent live
    build match.
16. Retention cleanup runs only for a safe terminal state and never removes
    the durable backup folder.

## Deployment package impact

Required target-side files:

1. `Start-TargetUpgrade.ps1`
2. `Update-UpgradeStatus.ps1`
3. `OSUpgradeShared.ps1`
4. `Remove-UpgradeArtifacts.ps1`
5. `setupcomplete.cmd`
6. `setuprollback.cmd`

Optional target-side files:

1. `LGPO.exe` - enables portable LGPO-format policy backup.
2. `Remove-OrphanedProfiles.ps1` - provides the reviewed remediation option
   when the orphan-profile check fails.

Server A also requires `Start-RemoteUpgradeOrchestrator.ps1`. Do not deploy only
the older five-file package; `OSUpgradeShared.ps1` is now a required runtime
dependency.

## Customer-visible behavior changes

- Some runs that previously continued will now stop with a clear safety error.
  This is intentional fail-closed behavior, not a regression.
- A failed precheck or kickoff now returns process exit code 1.
- An unconfirmed final build no longer becomes success after retries; the
  monitor continues until evidence arrives or exits 2 on timeout.
- During a telemetry gap, the display says `Unknown`/unconfirmed instead of
  asserting a specific reboot phase.
- A duplicate kickoff is rejected rather than allowed to overlap.
- Cleanup may defer and retry instead of deleting while another component is
  active.
- The backup folder now contains additional host diagnostic evidence.
- A production-like run stops instead of launching Setup when the required
  system-state backup was not created.
- An unconfirmed Setup launch is a failure rather than a warning.
- Assessment and monitoring can be tested separately without launching Setup.
- Disposable lab runs can independently skip DISM ScanHealth and SFC without
  changing the check count or hiding that either result is incomplete.
- Windows Setup no longer stops at the EULA action during an unattended run.
- A Setup failure during Downlevel is reported as `Failed` within one monitor
  poll instead of appearing as an indefinite Safe OS phase.
- The final live build check completes without an interactive prompt.
- Post-upgrade validation reports itself as a distinct in-progress phase and
  states that the upgrade is already finished, so the verification window is
  not mistaken for a stalled upgrade.
- The orchestrator log file now contains the target's own step-by-step output
  and a progress timeline, so the run can be reconstructed after the console
  is closed.
- The monitoring display shows the full phase lifecycle and how long the
  target's status has been unchanged.

## Exit-code contract

| Exit code | Meaning |
| --- | --- |
| `0` | Upgrade completed/validated, completed with warnings, or `-PrecheckOnly` published `AssessmentPassed`. |
| `1` | Assessment, kickoff, rollback or target-reported upgrade failure. |
| `2` | Monitoring ended without independently confirmed terminal success before timeout. The target upgrade may still be running; use `-MonitorOnly` to resume observation. |

## Exact file placement

The commands below assume the following Server A root:

```text
C:\OSUpgradeAutomation
```

The existing workspace can be used instead; set `$Root` to its actual path.

### Server A - management/orchestrator machine

Place the files in this exact relative structure:

```text
C:\OSUpgradeAutomation\
|-- ServerA-Orchestrator\
|   `-- Start-RemoteUpgradeOrchestrator.ps1
|-- ServerB-Target\
|   |-- Start-TargetUpgrade.ps1
|   |-- Update-UpgradeStatus.ps1
|   |-- OSUpgradeShared.ps1
|   |-- Remove-UpgradeArtifacts.ps1
|   |-- setupcomplete.cmd
|   |-- setuprollback.cmd
|   |-- Remove-OrphanedProfiles.ps1    (optional but recommended)
|   `-- LGPO.exe                       (optional)
|-- Tests\
|   |-- Orchestrator.Tests.ps1
|   |-- UpgradeStatus.Tests.ps1
|   `-- Run-SafeTests.ps1
|-- CHANGE-TRACKING.md
`-- PROJECT-NOTES.md
```

Important:

- Do not put the target files in `ServerA-Orchestrator`.
- `ServerB-Target` must be a sibling of `ServerA-Orchestrator`; that is the
  orchestrator's default discovery layout.
- Do not copy `LGPO.zip` into `ServerB-Target`. If portable local-GPO backup is
  required, extract the Microsoft utility and place the actual `LGPO.exe`
  there.
- Keep the exact `.cmd` filenames. Windows Setup requires those names.
- `OSUpgradeShared.ps1` is required. The run stops before target modification
  if it is absent.
- `Tests` and the Markdown files remain only on Server A/developer machines.

### Server B - disposable target test VM

Do **not** manually place the automation scripts on Server B for a normal
orchestrated run. Server A performs the following automatically:

1. Stages files in `C:\Temp\OSUpgradeStaging`.
2. Runs `Start-TargetUpgrade.ps1` from that staging folder.
3. Copies persistent runtime files to:

```text
C:\ProgramData\OSUpgradeAutomation\Scripts
```

Prepare these data locations on Server B:

```text
D:\ISO\<one matching newer Windows Server ISO>
D:\UpgradeBackup
```

The defaults used by the scripts are:

```text
ISO folder      : D:\ISO
Backup root     : D:\UpgradeBackup
Status JSON     : D:\upgrade_status.json
Remote staging  : C:\Temp\OSUpgradeStaging
Persistent data : C:\ProgramData\OSUpgradeAutomation
```

Use another non-system drive if `D:` does not exist, but pass the same custom
paths in every command. `BackupRoot` must not resolve to the Windows system
drive. Keep exactly one `.iso` file in the ISO folder so media selection is
unambiguous.

## Exact test runbook

### Test safety rules

1. Run local regression and `-PrecheckOnly` first.
2. Run a full upgrade only on a disposable, recoverable VM snapshot/clone.
3. Do not use `-SkipSystemStateBackup`, `-SkipPatchCheckLab`,
   `-SkipDismScanHealthLab` or `-SkipSfcScanNowLab` as proof of production
   readiness.
4. A full end-to-end test really installs the target OS and reboots the VM
   multiple times.
5. Use a dedicated elevated PowerShell console. The orchestrator intentionally
   exits its host with code 0, 1 or 2.
6. The examples use PowerShell only; no Python is required.

### Step 1 - verify the Server A package

Run in an elevated PowerShell console on Server A:

```powershell
$Root = 'C:\OSUpgradeAutomation'
$Required = @(
    'ServerA-Orchestrator\Start-RemoteUpgradeOrchestrator.ps1'
    'ServerB-Target\Start-TargetUpgrade.ps1'
    'ServerB-Target\Update-UpgradeStatus.ps1'
    'ServerB-Target\OSUpgradeShared.ps1'
    'ServerB-Target\Remove-UpgradeArtifacts.ps1'
    'ServerB-Target\setupcomplete.cmd'
    'ServerB-Target\setuprollback.cmd'
    'Tests\Orchestrator.Tests.ps1'
    'Tests\UpgradeStatus.Tests.ps1'
    'Tests\Run-SafeTests.ps1'
)

$Missing = @($Required | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf)
})
if ($Missing.Count) {
    throw "Package is incomplete:`n$($Missing -join "`n")"
}

Get-ChildItem -LiteralPath $Root -Recurse -File |
    Where-Object Extension -in '.ps1', '.cmd' |
    Unblock-File

Write-Host 'Required package files are present.' -ForegroundColor Green
```

Expected result: `Required package files are present.`

### Step 2 - run the non-operational PowerShell regression tests

These tests do not connect to Server B or execute an operational entry point:

```powershell
$Root = 'C:\OSUpgradeAutomation'
Set-Location -LiteralPath $Root

& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File '.\Tests\Run-SafeTests.ps1'

$TestExitCode = $LASTEXITCODE
if ($TestExitCode -ne 0) {
    throw "Safe test suite failed with exit code $TestExitCode."
}
```

Expected output includes:

```text
Syntax validation passed for 9 PowerShell files.
Orchestrator tests passed: 67
PASS: 88 isolated upgrade status/cleanup assertions
All safe tests passed. No operational entry point was executed.
```

If PowerShell 7 and PSScriptAnalyzer are installed, run the additional analyzer
gate:

```powershell
& pwsh.exe -NoProfile -NonInteractive `
    -File '.\Tests\Run-SafeTests.ps1' -Analyze

$AnalyzeExitCode = $LASTEXITCODE
if ($AnalyzeExitCode -ne 0) {
    throw "Analyzer test gate failed with exit code $AnalyzeExitCode."
}
```

Expected additional output:

```text
PSScriptAnalyzer: no Error-severity findings.
```

Stop here if either command fails.

### Step 3 - prepare the disposable Server B VM

Before the test:

1. Take a VM snapshot/checkpoint or other tested recoverable backup.
2. Confirm the source OS is a supported non-domain-controller,
   non-failover-cluster test server.
3. Copy exactly one newer, matching-edition and matching-installation-type ISO
   to `D:\ISO`.
4. Confirm `C:` has at least 32 GB free unless an approved higher threshold is
   used.
5. Reboot first if the server has a pending reboot.
6. Confirm PowerShell remoting is already enabled and the chosen listener is
   reachable.

Run on Server B:

```powershell
New-Item -ItemType Directory -Path 'D:\ISO' -Force | Out-Null
New-Item -ItemType Directory -Path 'D:\UpgradeBackup' -Force | Out-Null

$IsoFiles = @(Get-ChildItem -LiteralPath 'D:\ISO' -Filter '*.iso' -File)
if ($IsoFiles.Count -ne 1) {
    throw "D:\ISO must contain exactly one ISO; found $($IsoFiles.Count)."
}

Get-Volume -DriveLetter C, D |
    Select-Object DriveLetter, FileSystemLabel,
        @{Name='FreeGB'; Expression={[math]::Round($_.SizeRemaining / 1GB, 1)}}

Test-WSMan -ComputerName localhost
```

Expected result:

- Exactly one ISO is listed.
- `C:` has the required free space.
- `D:` is a separate data/backup volume.
- `Test-WSMan` succeeds.

If remoting is not configured, configure it only through the customer's
approved server-management policy. Do not weaken firewall, certificate or
TrustedHosts settings merely to make the test pass.

### Step 4 - verify Server A to Server B connectivity

Run on Server A:

```powershell
$Target = 'ServerB.contoso.com'

Resolve-DnsName -Name $Target
Test-NetConnection -ComputerName $Target -Port 5985
Test-NetConnection -ComputerName $Target -Port 5986
```

Use the applicable WinRM check:

```powershell
# HTTP/integrated authentication:
Test-WSMan -ComputerName $Target -Port 5985

# OR validated HTTPS:
Test-WSMan -ComputerName $Target -UseSSL -Port 5986
```

Only one WinRM listener needs to succeed. Ping can be blocked; it is advisory,
not the kickoff gate. The orchestrator separately verifies that the remote
execution identity is a member of the target's local Administrators group.

### Step 5 - run assessment only; no backup or Setup launch

Preferred domain/integrated-authentication command from Server A:

```powershell
$Root = 'C:\OSUpgradeAutomation'
$Target = 'ServerB.contoso.com'
$Script = Join-Path $Root 'ServerA-Orchestrator\Start-RemoteUpgradeOrchestrator.ps1'

& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $Script `
    -TargetComputer $Target `
    -IsoFolder 'D:\ISO' `
    -BackupRoot 'D:\UpgradeBackup' `
    -StatusJsonPath 'D:\upgrade_status.json' `
    -SkipDismScanHealthLab `
    -SkipSfcScanNowLab `
    -PrecheckOnly

$AssessmentExitCode = $LASTEXITCODE
Write-Host "Assessment exit code: $AssessmentExitCode"
```

For a target that exposes only validated HTTPS, add:

```powershell
-UseSSL
```

Use `-SkipCertificateCheck` only for an explicitly approved disposable lab
listener whose certificate cannot be validated. It weakens identity
verification and must not be the production default.

If an explicit credential is required, run the orchestrator in a child
PowerShell process so its `exit` does not close the operator's parent console:

```powershell
$Root = 'C:\OSUpgradeAutomation'
$Target = 'ServerB.contoso.com'
$Script = Join-Path $Root 'ServerA-Orchestrator\Start-RemoteUpgradeOrchestrator.ps1'

$ChildCommand = @"
`$Credential = Get-Credential
& '$Script' -TargetComputer '$Target' -Credential `$Credential ``
    -IsoFolder 'D:\ISO' -BackupRoot 'D:\UpgradeBackup' ``
    -StatusJsonPath 'D:\upgrade_status.json' -PrecheckOnly
"@

& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $ChildCommand
$AssessmentExitCode = $LASTEXITCODE
Write-Host "Assessment exit code: $AssessmentExitCode"
```

Expected pass result:

- Process exit code: `0`.
- Target status: `AssessmentPassed`.
- Target phase: `1`.
- A precheck report exists.
- No backup stage, Setup launch or upgrade reboot occurs.
- The DISM check appears as WARN and states that component-store health was not
  validated; `Dism.exe /ScanHealth` was not run.
- The SFC check appears as WARN and states that protected system-file integrity
  was not validated; `sfc.exe` and CBS.log analysis were not run.

Verify on Server B:

```powershell
$Status = Get-Content -LiteralPath 'D:\upgrade_status.json' -Raw |
    ConvertFrom-Json
$Status | Format-List Phase, PhaseName, Status, PercentComplete, Notes

Get-ChildItem -LiteralPath 'D:\UpgradeBackup' `
    -Filter 'PreCheckReport_*.log' -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 FullName, LastWriteTime

Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\OSUpgradeAutomation' |
    Select-Object Phase, PhaseName, Status, LastUpdated
```

Expected values:

```text
Phase           : 1
PhaseName       : Pre-Upgrade Assessment
Status          : AssessmentPassed
PercentComplete : 100
```

Assessment-only is not zero-write: it stages files, writes logs/registry/JSON
and a report, and may mount the ISO. It does not perform the backup stage,
register the upgrade tasks or launch Setup.

Remove both `-SkipDismScanHealthLab` and `-SkipSfcScanNowLab` when the purpose
of the assessment is to prove production readiness. These flags accelerate
repeat functional testing only.

If the exit code is `1`, correct every reported hard failure and rerun
`-PrecheckOnly`. Do not advance to a full upgrade.

### Step 6 - optional negative safety tests

Use separate disposable snapshots for these tests:

1. Run with a non-administrator credential. Expected: failure before staging
   or kickoff.
2. Run with an invalid status path such as a UNC path. Expected: local
   parameter rejection before connecting.
3. Hold the starter mutex on Server B and start another assessment. Expected:
   duplicate execution is rejected.

To hold the mutex temporarily on Server B:

```powershell
$Mutex = [System.Threading.Mutex]::new(
    $false,
    'Global\OSUpgradeAutomation.StartTargetUpgrade'
)
$OwnsMutex = $Mutex.WaitOne(0)
if (-not $OwnsMutex) { throw 'Mutex is already owned.' }
Read-Host 'Mutex held. Run the duplicate-start test, then press Enter'
$Mutex.ReleaseMutex()
$Mutex.Dispose()
```

Never terminate the mutex-holding console without releasing it intentionally;
an abandoned mutex is recoverable, but that is not the behavior being tested.

### Step 7 - run a fast full smoke upgrade on a disposable VM

This step **actually upgrades and reboots Server B**.

For a fast functional smoke test only:

```powershell
$Root = 'C:\OSUpgradeAutomation'
$Target = 'ServerB.contoso.com'
$Script = Join-Path $Root 'ServerA-Orchestrator\Start-RemoteUpgradeOrchestrator.ps1'

& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $Script `
    -TargetComputer $Target `
    -IsoFolder 'D:\ISO' `
    -BackupRoot 'D:\UpgradeBackup' `
    -StatusJsonPath 'D:\upgrade_status.json' `
    -SkipDismScanHealthLab `
    -SkipSfcScanNowLab `
    -SkipSystemStateBackup `
    -DisableAutoCleanup `
    -PollIntervalSeconds 5 `
    -FastPollIntervalSeconds 2 `
    -TimeoutMinutes 240

$SmokeExitCode = $LASTEXITCODE
Write-Host "Smoke-upgrade exit code: $SmokeExitCode"
```

Add `-SkipPatchCheckLab` only if the disposable lab VM intentionally does not
meet the patch-age gate. It does not materially accelerate Setup; it merely
allows that known lab exception.

Why these smoke flags:

- `-SkipSystemStateBackup` removes the slowest backup step.
- `-SkipDismScanHealthLab` omits the read-only DISM component-store scan.
  The report shows WARN/unverified.
- `-SkipSfcScanNowLab` omits SFC and supplementary CBS.log analysis. The
  report shows WARN/unverified.
- `-DisableAutoCleanup` preserves evidence for inspection.
- Short polling improves test visibility; it does not make Windows Setup
  complete faster.

This smoke run is **not** production acceptance because it deliberately omits
DISM, SFC and the system-state backup.

### Step 8 - run a production-like lab upgrade

Restore a clean disposable snapshot and repeat without weakening flags:

```powershell
$Root = 'C:\OSUpgradeAutomation'
$Target = 'ServerB.contoso.com'
$Script = Join-Path $Root 'ServerA-Orchestrator\Start-RemoteUpgradeOrchestrator.ps1'

& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $Script `
    -TargetComputer $Target `
    -IsoFolder 'D:\ISO' `
    -BackupRoot 'D:\UpgradeBackup' `
    -StatusJsonPath 'D:\upgrade_status.json' `
    -DisableAutoCleanup `
    -TimeoutMinutes 240

$LabExitCode = $LASTEXITCODE
Write-Host "Production-like lab exit code: $LabExitCode"
```

Do not pass `-SkipPatchCheckLab`, `-SkipDismScanHealthLab`,
`-SkipSfcScanNowLab` or `-SkipSystemStateBackup`. Test
`-UseControlledReboot` separately on another restored snapshot; it changes
reboot orchestration and should have its own result record.

### Step 9 - resume monitoring without restarting the upgrade

If the Server A console closes, the monitor times out, or Server A restarts,
do not run a normal kickoff command blindly. Resume with:

```powershell
$Root = 'C:\OSUpgradeAutomation'
$Target = 'ServerB.contoso.com'
$Script = Join-Path $Root 'ServerA-Orchestrator\Start-RemoteUpgradeOrchestrator.ps1'

& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $Script `
    -TargetComputer $Target `
    -StatusJsonPath 'D:\upgrade_status.json' `
    -MonitorOnly `
    -PollIntervalSeconds 5 `
    -FastPollIntervalSeconds 2 `
    -TimeoutMinutes 60

$MonitorExitCode = $LASTEXITCODE
Write-Host "Monitor-only exit code: $MonitorExitCode"
```

Use the same `-UseSSL`, `-SkipCertificateCheck` and credential approach as the
original run. `-MonitorOnly` never stages files or launches Setup.

### Step 10 - inspect live target evidence

Run on Server B while the upgrade is in a Windows phase where PowerShell is
available:

```powershell
Get-Content -LiteralPath 'D:\upgrade_status.json' -Raw |
    ConvertFrom-Json |
    Format-List *

Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\OSUpgradeAutomation' |
    Format-List *

Get-ScheduledTask -TaskName 'OSUpgrade*' -ErrorAction SilentlyContinue |
    Select-Object TaskName, State

Get-ChildItem -LiteralPath 'C:\ProgramData\OSUpgradeAutomation\Logs' -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object Name, Length, LastWriteTime
```

The Server A orchestrator log is under:

```text
C:\ProgramData\OSUpgradeAutomation\OrchestratorLogs
```

The main Server B runtime logs are under:

```text
C:\ProgramData\OSUpgradeAutomation\Logs
```

The durable per-run evidence is under:

```text
D:\UpgradeBackup\<timestamp>
```

### Step 11 - verify final success

Run on Server B after Server A reports exit code 0:

```powershell
$Status = Get-Content -LiteralPath 'D:\upgrade_status.json' -Raw |
    ConvertFrom-Json

if ($Status.Status -notin 'Completed', 'CompletedWithWarnings') {
    throw "Unexpected terminal status: $($Status.Status)"
}
if ([int]$Status.Phase -ne 7) {
    throw "Expected Phase 7, got $($Status.Phase)."
}
if (-not $Status.TargetBuild -or
    $Status.PostUpgradeBuild -ne $Status.TargetBuild) {
    throw "Validated build does not match target build."
}
if ($Status.PostUpgradeValidationResult -notin
    'Passed', 'PassedWithWarnings') {
    throw "Post-upgrade validation did not pass."
}
if (-not $Status.PostUpgradeValidationTime) {
    throw "Post-upgrade validation timestamp is missing."
}

$LiveOS = Get-CimInstance -ClassName Win32_OperatingSystem
if ($LiveOS.BuildNumber -ne $Status.TargetBuild) {
    throw "Live build $($LiveOS.BuildNumber) does not match target $($Status.TargetBuild)."
}

Write-Host 'Upgrade result and live build are verified.' -ForegroundColor Green
```

Verify backup evidence:

```powershell
$RegistryState = Get-ItemProperty `
    -LiteralPath 'HKLM:\SOFTWARE\OSUpgradeAutomation'
$BackupFolder = $RegistryState.BackupFolder

if (-not (Test-Path -LiteralPath $BackupFolder -PathType Container)) {
    throw "Backup folder is missing: $BackupFolder"
}

Get-ChildItem -LiteralPath $BackupFolder -Recurse -File |
    Select-Object FullName, Length, LastWriteTime

foreach ($Name in 'computerinfo.txt', 'systeminfo.txt', 'ipconfig.txt') {
    if (-not (Test-Path -LiteralPath (Join-Path $BackupFolder $Name))) {
        throw "Missing diagnostic backup file: $Name"
    }
}
```

For the production-like run, also verify that the system-state backup exists
and perform the approved restore-validation procedure. A log line alone is not
a recovery test.

### Step 12 - test cleanup only after evidence review

Do not use `-Force` for the normal completed-run cleanup test.

Run on Server B after the result and backup have been reviewed:

```powershell
$CleanupScript = 'C:\ProgramData\OSUpgradeAutomation\Scripts\Remove-UpgradeArtifacts.ps1'
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $CleanupScript

$CleanupExitCode = $LASTEXITCODE
Write-Host "Cleanup exit code: $CleanupExitCode"
```

Verify:

```powershell
Test-Path -LiteralPath 'HKLM:\SOFTWARE\OSUpgradeAutomation'
Test-Path -LiteralPath 'D:\upgrade_status.json'
Test-Path -LiteralPath 'C:\ProgramData\OSUpgradeAutomation'
Test-Path -LiteralPath 'D:\UpgradeBackup'

Get-ScheduledTask -TaskName 'OSUpgrade*' -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath 'D:\UpgradeBackup' -Recurse `
    -Filter 'OSUpgradeCleanup_*.log' -File
```

Expected result:

- Registry status key: absent.
- Status JSON: absent.
- ProgramData tracking directory: absent.
- `OSUpgrade*` tasks: absent.
- `D:\UpgradeBackup`: still present.
- A durable cleanup log exists in the run backup folder.

### Recommended test sequence and acceptance record

| Test | Snapshot | Flags | Expected |
| --- | --- | --- | --- |
| Local regression | Not applicable | `Run-SafeTests.ps1` | 67 + 88 assertions pass |
| Fast assessment | Clean VM | `-PrecheckOnly -SkipDismScanHealthLab -SkipSfcScanNowLab` | Exit 0, `AssessmentPassed`, DISM/SFC WARN and unverified, no Setup |
| Production-readiness assessment | Clean VM | `-PrecheckOnly` | Exit 0, DISM and SFC both run, `AssessmentPassed`, no Setup |
| Negative safety | Separate clean VM states | Invalid input/non-admin/held mutex | Safe rejection |
| Fast smoke upgrade | Disposable clone | `-SkipDismScanHealthLab -SkipSfcScanNowLab -SkipSystemStateBackup -DisableAutoCleanup` | Full functional path, not production acceptance |
| Production-like lab | Restored clean clone | No skip flags, `-DisableAutoCleanup` | Backup + upgrade + validation pass |
| Controlled reboot | Separate restored clone | `-UseControlledReboot` | Controlled reboot path passes |
| Resume monitoring | Any active full-upgrade test | `-MonitorOnly` | No restaging or duplicate kickoff |
| Cleanup | Completed reviewed run | No `-Force` | Tracking removed; backup retained |

Record for each test:

- Source OS/build and edition.
- Target ISO name, image index, build and edition.
- Exact command and flags.
- Start/end timestamps and exit code.
- Final JSON and registry status.
- Backup folder and restore-validation result.
- Orchestrator, target, Setup and cleanup logs.
- VM snapshot/checkpoint used for rollback.

## Faster, safer checks

Run from this directory:

```powershell
# Completely local, isolated regression tests. No real target or admin rights needed.
powershell.exe -NoProfile -NonInteractive -File .\Tests\Run-SafeTests.ps1

# Also run installed PSScriptAnalyzer (Error severity is the gate).
pwsh.exe -NoProfile -File .\Tests\Run-SafeTests.ps1 -Analyze

# Assess a lab target without backup or Windows Setup.
.\ServerA-Orchestrator\Start-RemoteUpgradeOrchestrator.ps1 `
    -TargetComputer TestVM -PrecheckOnly `
    -SkipDismScanHealthLab -SkipSfcScanNowLab

# Observe existing state for one minute; never launch an upgrade.
.\ServerA-Orchestrator\Start-RemoteUpgradeOrchestrator.ps1 `
    -TargetComputer TestVM -MonitorOnly -TimeoutMinutes 1 `
    -PollIntervalSeconds 2 -FastPollIntervalSeconds 1
```

Assessment-only is **not a zero-write dry run**: staging, logs/reports and
temporary media mounting can occur. Monitoring-only still writes management-side
logs, performs read-only network probes and reports timeout if no terminal result
is confirmed. Short polling controls only sleep intervals; network operations
also take time.

Existing `-SkipPatchCheckLab`, `-SkipDismScanHealthLab`,
`-SkipSfcScanNowLab` and `-SkipSystemStateBackup` weaken protection or evidence
for an actual upgrade. They are not production-readiness tests and do not
replace a tested recovery plan. Do not use them merely to make a production
upgrade faster.

## Verification evidence

Verification was performed using PowerShell only:

- Windows PowerShell 5.1:
  - All 9 PowerShell files parsed successfully.
  - 67 orchestrator assertions passed.
  - 88 status/cleanup assertions passed.
- PowerShell 7:
  - The same isolated test suite passed.
  - PSScriptAnalyzer reported zero Error-severity findings.
- `git diff --check` reported no whitespace errors.

No Python was used. No operational entry point was executed during these tests,
so no local or remote OS upgrade, registry mutation, scheduled-task change,
backup, reboot or cleanup was performed by the regression suite.

## Production acceptance still required

Passing isolated tests is not certification of a Windows Server upgrade. Before
rollout, run the following on disposable, recoverable lab VMs using the actual
supported source OS, intended installation media and deployment credentials:

- Assessment failures: pending reboot, insufficient disk, incompatible media,
  missing administrator rights, DISM/SFC errors, profile and role checks.
- Backup: required artifacts, native command failure, low destination space,
  Windows Server Backup feature installation/reboot behavior and a restore drill.
- Full upgrade through actual reboots; both normal and controlled-reboot modes.
- Explicit credentials and integrated authentication over HTTP and validated
  HTTPS; blocked ICMP, SMB and DCOM; interrupted management connection.
- Duplicate kickoff during assessment/backup/Setup, management restart,
  rollback, failed setup launch and unreadable/stale state.
- Post-upgrade service comparison, missing baselines, failed validation, and
  cleanup preview/retention while another operation is active.

Do not roll out broadly until these checks pass with recoverable backups and
an approved maintenance/recovery window. None of those destructive integration
scenarios was performed on the development machine.

## Suggested customer change-record wording

> The Windows Server in-place-upgrade automation was hardened without changing
> its intended upgrade workflow. The release adds fail-closed startup and final
> verification, prevents concurrent upgrade/monitor/cleanup operations,
> validates remote administrator access, improves status transport and backup
> evidence, and introduces non-upgrading assessment and monitoring modes.
> Success is now reported only when the target-side validation and an
> independent live build check agree. Cleanup and optional profile remediation
> include additional safeguards against unintended deletion. PowerShell-only
> regression testing completed successfully; a recoverable VM integration run
> remains required before production rollout.
