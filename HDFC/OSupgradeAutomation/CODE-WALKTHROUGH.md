# OS Upgrade Automation - Source-Level Code Walkthrough

This document explains the runtime code in execution order. It describes what
PowerShell evaluates, what state is changed, which process or account performs
the work, and how control passes between files.

## 1. Runtime Components and Process Boundaries

There are seven runtime files:

| File | Runs on | Process/account | Purpose |
|---|---|---|---|
| `ServerA-Orchestrator/Start-RemoteUpgradeOrchestrator.ps1` | Server A | Interactive operator process | Validates connectivity, copies files, starts target work, and monitors it |
| `ServerB-Target/Start-TargetUpgrade.ps1` | Server B | Initially a WinRM-hosted PowerShell process | Runs prechecks and backups, creates durable state, registers tasks, and hands Windows Setup to Task Scheduler |
| `ServerB-Target/OSUpgradeStatus.ps1` | Server B; pure JSON/history helpers also loaded on A | Dot-sourced shared functions | Owns registry/JSON schema, weighted progress, writer mutex, atomic writes, phase-history normalization, and reboot evidence |
| `ServerB-Target/Update-UpgradeStatus.ps1` | Server B | SYSTEM scheduled task or hook-launched PowerShell | Determines the current Setup phase and performs final validation |
| `ServerB-Target/setupcomplete.cmd` | Server B | Windows Setup PostOOBE context | Marks successful OOBE completion and immediately invokes the status engine |
| `ServerB-Target/setuprollback.cmd` | Server B | Windows Setup PostRollback context | Marks rollback and immediately invokes the status engine |
| `ServerB-Target/Remove-UpgradeArtifacts.ps1` | Server B | SYSTEM cleanup task or an elevated operator | Removes disposable tracking state after a terminal result |

The most important process boundary is the Setup launch. The target script is
started through WinRM, but `setup.exe` is not kept as a child of that remote
process. It is launched by a local scheduled task as SYSTEM. Consequently,
closing Server A, losing WinRM, or terminating the orchestrator does not stop
Windows Setup.

## 2. Shared Persistent-State Contract

The target scripts communicate through durable state rather than in-memory
variables. Their common registry root is:

```text
HKLM:\SOFTWARE\OSUpgradeAutomation
```

Important values include:

| Value | Meaning |
|---|---|
| `Phase` | Technical phase number: 1, 2, 3, 4, 5, 6, 7, or 99 |
| `PhaseName` | Human-readable phase name |
| `Stage` | Customer-facing grouping: prechecks, backup, or Setup execution |
| `Status` | Normally `InProgress`, `Completed`, `CompletedWithWarnings`, or `Failed` |
| `RunId` / `Sequence` | Stable run identity and monotonically increasing publication number |
| `PercentComplete` / `OverallPercentComplete` | Monotonic end-to-end workflow percentage; the legacy name is retained for consumers |
| `StagePercentComplete` | Local 0-100 progress inside the active stage |
| `PhasePercentComplete` | Local 0-100 value for the current technical phase; resets at a phase boundary |
| `PercentSource` | Whether the retained numeric value is measured or estimated |
| `ProgressSource` | Concrete producer, such as task count, MoSetup, Event 1074, or validation |
| `ProgressFreshness` | `Live`, `Milestone`, `CarriedForward`, or `Terminal` |
| `ProgressUpdatedAtUtc` / `StatusUpdatedAtUtc` | Separate numeric-sample and status-publication timestamps |
| `ExpectedDisconnect` | A restart request was observed; not proof of Safe OS, and never an exemption from liveness checks |
| `RebootCount` / `LastObservedBootTimeUtc` / `BootEvidence` | Unique boots counted by `LastBootUpTime`, corroborated by Events 12 and 6005 |
| `UnexpectedRestartAtUtc` | Kernel-Power Event 41 corroborates an unexpected restart |
| `SetupPhaseHistory` | Current-run Setup execution starts, with original timestamps and evidence; includes phases recovered retrospectively |
| `MonitorLastError` | Explicit target monitor error, retained for the orchestrator to report |
| `VerifiedTargetBuild` / `CompletionEvidence` | Local validation result and PostOOBE or clear-Setup-flags evidence |
| `UserProfileCount` / `SpecialProfileCount` / `TotalProfileCount` | Non-special user profiles, system profiles, and their total from `Win32_UserProfile` |
| `LoadedUserProfileCount` / `UserProfileInventoryPath` | Loaded non-special count and per-profile CSV location |
| `DirtyBitCheckStatus` / `OrphanedProfileCheckStatus` | Explicit precheck outcome, including `Unknown` or an explicitly `Skipped` orphan check |
| `UserProfileInventoryStatus` | `Collected` or `Unavailable`; profile counting is warning-only with no blocking threshold |
| `PendingFileRenameCheckStatus` | Outcome of only the pending-file-rename gate; bypass does not apply to CBS/Windows Update |
| `SourceBuild` | Windows build before Setup starts |
| `TargetBuild` | Build extracted from the selected WIM/ESD image |
| `StatusJsonPath` | Location of the externally readable JSON status file |
| `BackupFolder` | Timestamped backup folder for this run |
| `StartTime` / `LastUpdated` | Run and latest-state timestamps |
| `Notes` | Current detailed status or failure reason |

The fixed workflow ranges are prechecks 0-10, backup 10-25, Downlevel 25-50,
Safe OS 50-70, First Boot 70-85, Second Boot 85-95, and validation 95-100.
These are workflow weights, not elapsed-time predictions or a copy of Setup's
UI percentage. The supplied September 29 log reaches Downlevel 100% before
Safe OS begins, so the MoSetup counter must not map directly into 25-95.
`SetupTelemetryPercent` and `SetupTelemetryPhase` preserve the raw observation.
`StagePercentComplete` remains cumulative across the whole Setup stage.
Missing telemetry carries the last verified value; a confirmed phase boundary
can advance its milestone. Failure/rollback retain the high-water. Only a
successful terminal validation publishes 100 overall.

The default target JSON is `D:\upgrade_status.json`. The orchestrator can read
it through `\\ServerB\D$\upgrade_status.json` without using WinRM. Every write
uses a process-unique temporary file and atomic replacement while a named
cross-process mutex serializes the two target writers.
Readers do not open that writer mutex: a global mutex created under SYSTEM's
default ACL can deny access to an otherwise authorized WinRM administrator.
The WinRM reader uses published JSON, or a reported read-only registry
fallback, without dot-sourcing or executing target writer code.

`Write-UpgradeJsonFile` is shared by the target publisher and Server A mirror.
It uses an explicit null backup filename for `File.Replace` and retries brief
I/O replacement conflicts. It never falls back to `Move-Item -Force` over an
existing file or deletes the last good status before replacing it.
After an OS hive migration, the target publisher reconciles its sequence and
high-water percentage against the existing JSON for the same `RunId`.
An old run's JSON cannot seed a new run. This avoids the observed post-boot
54-vs-56 sequence rejection loop.

Server A also maintains an atomic local mirror, by default under
`C:\ProgramData\OSUpgradeAutomation\OrchestratorLogs`. Producer fields remain
unchanged during a target outage; an `Observer` object records connectivity,
cache age, and whether the snapshot is fresh, carried forward, or recovered
from a prior orchestrator process.

Durable target files are stored below:

```text
C:\ProgramData\OSUpgradeAutomation\
  Logs\
  Scripts\
  postoobe.marker
  rollback.marker
```

Backups and the durable progress history are stored separately under
`D:\UpgradeBackup`. Automatic cleanup never deletes that backup root.

## 3. Server A Orchestrator

File: `ServerA-Orchestrator/Start-RemoteUpgradeOrchestrator.ps1`

### 3.1 Parameter binding and error policy

`TargetComputer` is mandatory. `Credential` is optional, so an omitted value
means integrated authentication using the account running the orchestrator.
When `-Credential` is supplied, WinRM explicitly uses `-Authentication Negotiate`,
matching the customer-tested reference script. No additional orchestrator
switch is needed. Calls without explicit credentials retain their existing
authentication defaults.

The following values are passed to the target script:

- `IsoFolder`: where Server B searches for ISO files.
- `MinFreeSpaceGB`: minimum free space required on the system drive.
- `BackupRoot`: non-system-drive backup root.
- `StatusJsonPath`: registry-state JSON mirror.
- `RetentionDays`: delay from kickoff until the one-time cleanup task runs.
- `DisableAutoCleanup`: prevents cleanup-task registration.
- `SkipPatchCheckLab`: changes a patch failure to a warning.
- `SkipSystemStateBackup`: deliberately omits `wbadmin`.
- `SkipOrphanedProfileCheck`: explicitly skips only the blocking SID-resolution
  check, logs WARN/Skipped, and leaves profile counting and other gates enabled.
- `SkipUserProfileCountCheck`: deprecated, accepted for command-line
  compatibility only. Inventory and its duration warning always run; no
  profile-count bypass is needed.
- `SkipPendingFileRenameCheck`: bypasses only the `PendingFileRenameOperations`
  blocker. It still reports operations and does not delete the registry value.
- `MinVMwareToolsVersion`: minimum accepted Tools version on VMware.
- `UseControlledReboot`: adds `/NoReboot` and lets the target script restart.
- `MaxPatchAgeDays`: hotfix-age fallback threshold.

The remaining parameters control only Server A monitoring. The default normal
poll is 15 seconds, the disconnected poll is 5 seconds, and the total monitor
window is 180 minutes. `LocalStatusMirrorPath` optionally overrides the
always-readable Server A JSON mirror location.
`StatusStaleWarningMinutes` defaults to five and applies even when the same
old status file remains readable. Each individual monitoring probe is bounded;
the poll interval is the sleep after those probes, not a guaranteed sampling rate.
`FinalValidationTimeoutSeconds` defaults to 60. Once the target reports
completion, the orchestrator shows one "Validating update for a few seconds"
message and retries live verification within this separate short budget
(also capped by the remaining overall monitoring budget).

`$ErrorActionPreference = "Stop"` promotes most PowerShell errors into
terminating errors. Local `try/catch` blocks then decide which failures are
fatal and which are deliberately tolerated.

### 3.2 Local logging

The script creates:

```text
C:\ProgramData\OSUpgradeAutomation\OrchestratorLogs\
```

`Write-Log` builds a timestamped line, selects a console color by severity,
prints it, and appends it to the run-specific log. Logging itself is not wrapped
in a defensive catch, so a failure to create or append the local log is fatal
under the global error policy.

`Write-LocalStatusMirror` atomically publishes the latest real target snapshot
plus a separate `Observer` envelope. It never replaces producer fields with
synthetic Offline or Heartbeat values. `Import-LocalStatusMirrorCache` restores
the last producer snapshot if the orchestrator restarts while Server B is
unreachable and marks it `RecoveredFromDisk` until a fresh read arrives.

### 3.3 WinRM transport resolution

`$script:WinRMProbeScript` is a script block designed to run in a background
job. It supports three explicit transports:

1. `Http`: `Test-WSMan` on port 5985.
2. `Https`: `Test-WSMan -UseSSL` on port 5986 with normal certificate checks.
3. `HttpsSkipCert`: opens and immediately removes a real PSSession using
   `SkipCACheck`, `SkipCNCheck`, and `SkipRevocationCheck`.

The third form uses `New-PSSession` because `Test-WSMan` cannot accept a
session option that bypasses certificate checks.

`Test-WinRMTransport` starts that script block as a job, waits up to 15 seconds,
returns its Boolean result, and always stops/removes the job in `finally`. This
is a timeout wrapper around commands that otherwise have no short per-call
timeout.

`Resolve-WinRMTransport` constructs its trial order. Unless `-UseSSL` was
specified, HTTP is tried first. Validated HTTPS follows. Certificate-bypassed
HTTPS is only added when the operator explicitly supplied
`-SkipCertificateCheck`. The selected transport is stored once in
`$script:WinRMTransport`.

`Get-WinRMSessionParams` converts that selection into one splatted hashtable.
Every later PSSession and Invoke-Command uses the same transport and optional
credential.
Explicit-credential Negotiate also applies to all three probe transports,
the independent WinRM JSON reader, the live status/build reader (including
final validation), and the read-only readiness command. Session-based staging,
file copies, and target kickoff inherit the authenticated PSSession. The
independent DCOM fallback is unchanged.

Negotiate selects Kerberos or NTLM according to the target/account context
and Windows policy. It does not enable WinRM, open firewalls, bypass HTTPS
certificate checks, or edit TrustedHosts. IP-address/workgroup targets still
need an approved HTTPS or narrowly scoped TrustedHosts configuration and
permission to use the negotiated authentication mechanism.

### 3.4 Local-file and reachability preflight

The required file array contains exactly the six staged target-side files,
including `OSUpgradeStatus.ps1`.
`LGPO.exe` is optional.

If the normal sibling `ServerB-Target` directory is absent, the script checks
whether all six required files are beside the orchestrator. This supports a
flat deployment layout. Each required path is then tested individually. A
missing file throws before any remote change occurs.

`Test-Connection` is diagnostic only. Its failure logs a warning because ICMP
can be blocked while management protocols remain available.

WinRM transport resolution is the real gate. If no transport answers, the
script throws with listener, firewall, certificate, and TrustedHosts guidance.

### 3.5 Existing-run and resume decision

An `Invoke-Command` reads the target registry state and enriches it with live
evidence:

- Whether `setup`, `SetupHost`, or `SetupPrep` is running.
- The age of `C:\$WINDOWS.~BT\Sources\Panther\setupact.log`.
- The current OS caption and build from `Win32_OperatingSystem`.

For precheck/backup state, activity evidence still helps distinguish abandoned
kickoff work. Once Setup has been entered (Phase 3 or later), unresolved
`InProgress` state always resumes monitoring, even with no Setup process.
Otherwise a forced reset or missing completion hook could cause a second
Setup launch and destroy useful diagnostic state.

The decision table is:

| Stored condition | Orchestrator action |
|---|---|
| In progress plus live evidence | Set `resumeExisting`; do not copy or relaunch |
| Completed or completed with warnings | Resume final live verification; a stored completion record alone is not success |
| In progress at Phase 3 or later without live evidence | Resume monitoring and reconcile interruption/completion; never relaunch Setup |
| Precheck/backup state without live evidence | Allow normal kickoff, subject to the target's own guard |
| No usable state or query failure | Assume a new run |

The target script independently repeats the active/stale test. That duplication
is intentional: Server A avoids unnecessary work, while Server B protects
itself if invoked directly or if Server A's conclusion was stale.

### 3.6 Time-bounded remote file reads

`Read-RemoteFileWithTimeout` starts a job that performs `Test-Path` and
`Get-Content -Raw` against a UNC path. The caller gets either content, null, or
an explanatory out-parameter. The job is always removed. This prevents SMB
negotiation against a rebooting server from blocking the entire monitor.

### 3.7 Staging and invoking Server B

For a new run, Server A opens a PSSession, creates
`C:\Temp\OSUpgradeStaging`, and copies only the named required files. It does
not wildcard-copy unrelated files. `LGPO.exe` is copied only when present.

The target invocation is an `Invoke-Command -AsJob`. The second script-block
parameter is deliberately called `$ArgMap`; naming it `$Args` would collide
case-insensitively with PowerShell's automatic `$args` variable.

The remote block builds a splat. False Boolean values are omitted, while true
ones become switches. It catches target exceptions and returns exactly one
structured result:

```powershell
[pscustomobject]@{ Success = $true_or_false; Error = $message_or_null }
```

While that job runs, the orchestrator drains output with `Receive-Job`, polls
the status JSON at most once per `PollIntervalSeconds`, refreshes the Server A
mirror, and displays a spinner plus the current overall percentage. The
percentage is sticky during a transient failed or partial JSON read.
The default payload-read interval is 15 seconds, not every three spinner ticks.
SMB gets a five-second budget and
the separate WinRM JSON fallback gets fifteen seconds including job startup.
The console spinner still refreshes between reads. Starting a new upgrade
clears the old producer cache; the target handoff returns the new `RunId`,
so a previously recovered mirror cannot pin the new monitor to an old run.

After completion, the script selects the one received object containing a
`Success` property. A missing result is converted into an explicit failure.

Precheck/kickoff failures are printed as a clean banner. Pending reboot and
orphaned-profile failures receive specialized remediation. The re-run command
is reconstructed from the actual bound parameters, preserving switches,
numbers, strings, and credential handling.

Important behavior: after this banner, `$upgradeKickoffOk` remains false and
the script executes `return`. It does not explicitly `exit 1`; therefore a
caller relying on the process exit code may not receive a nonzero precheck
failure code.

### 3.8 Status acquisition channels

`Get-UpgradeStatus` probes connectivity and selects usable status in this order:

1. ICMP ping.
2. A bounded WinRM probe using the previously selected transport.
3. Fresh atomic JSON through the drive's administrative share.
4. One WinRM read of published status and OS build/Setup flags when SMB status
   is absent or stale (fifteen-second whole-call cap).
5. Registry values through CIM with a DCOM session (eight-second whole-read cap).

Healthy SMB polling does not start an extra remote PowerShell payload session,
query CIM boot time, or inspect Task Scheduler on every poll. A stale file
does not suppress usable WinRM/DCOM status. Different run IDs, older-boot
snapshots, and older same-boot sequences are rejected. A confirmed newer
`LastObservedBootTimeUtc` allows a migrated registry's lower sequence until the
publisher reconciles it. The producer's overall high-water is preserved.

The WinRM reader is passive by default. The caller explicitly requests task
recovery only after a nonterminal publication is at least two minutes stale,
and throttles those requests to at most once per minute. Normal final
verification also reads passively. Repeated payload-read failures remain in
the log but are not repeatedly printed as new console warnings.
If the task was lost during upgrade, it recreates only the status monitor from
the already-staged script. It never relaunches Setup. Missing scripts, disabled
tasks, and repair errors are surfaced rather than treated as success.

Modes mean:

| Mode | Exact meaning |
|---|---|
| `ActivePolling` | WinRM endpoint answered, regardless of ping; a usable payload is still independently required |
| `Heartbeat` | WinRM did not answer, but ping or another channel did |
| `Offline` | Ping, WinRM, SMB status, and DCOM status all failed |

The fallback objects intentionally have no numeric `Phase`. They describe
connectivity, not a confirmed Windows Setup phase.

### 3.9 Monitoring state machine

The main loop retains several independent high-water marks:

- Last confirmed phase name.
- Last confirmed numeric phase.
- Last mode and disconnection start time.
- Last known percentage and source.
- Target build.
- Time spent in the current confirmed phase.

A fresh percentage is clamped so that it cannot decrease while Status is
`InProgress`. A poll without a percentage displays the last known value with
`(cached)`. Target-side terminal failure retains the achieved high-water mark;
`Status`, `IsTerminal`, and `Notes` communicate the failure independently.

A fallback connectivity result displays the last confirmed phase with an
explicit “unconfirmed” qualifier. It does not pretend that every outage is
Safe OS. When real data returns, the script reports whether the phase changed
or remained the same.

If numeric phases jump, for example from 3 to 6, the monitor explains that
Safe OS has no normal management services and First Boot can finish between
polls. This is an observation gap, not necessarily an execution gap.

`PhaseStallWarningMinutes` only emits escalating warnings. It never changes
status or stops the loop.
The independent five-minute status watchdog also works during complete
outages and when repeated reads return the same old snapshot. The progress
display, console, and mirror's `Observer.HealthWarning` report the last phase
and the need to check the target. `Observer.ProducerStatusAgeSeconds` is the
age of publication, distinct from the age of the last successful read.
Historical Setup phase starts are printed once per run with their original
timestamps and explicitly labeled as recovered, not live observations.

Every poll also updates the Server A mirror. File/DCOM records replace the
producer snapshot; WinRM-only, heartbeat, offline, timeout, and polling-error
records update only `Observer`, preserving `RunId`, `Sequence`, phase, and
percentage from the last target-produced status.

The loop terminates in four ways:

- Server B reports `Failed`.
- Server B reports a successful terminal state, WinRM is active, and the build
  is independently confirmed.
- Server A's overall monitoring timeout expires.
- The target reports completion but Server A cannot verify it within the
  final-validation grace period.

Final verification uses the same bounded WinRM live observation and resolved
HTTP/HTTPS transport. The live build must match and both
`SystemSetupInProgress` and `OOBEInProgress` must be present and zero. Failed
queries never become success after a retry count; the overall deadline still
ends monitoring with an unverified outcome.
`Wait-UpgradeCompletion` checks immediately, with five-second delays between
subsequent retries and a probe timeout no larger than its remaining budget.
The progress UI shows "Validating update..." instead of repeated console
warnings. Detailed errors still go to the orchestrator log and local mirror.
A verified result prints the normal summary immediately. An exhausted grace
period produces an explicit validation error; `Observer.ConnectivityMode`
becomes `ValidationFailed`, with an explanation in `ObservationError` and
`HealthWarning`. The target's producer status is preserved: inability to
verify does not prove that the OS upgrade itself failed.

The October 1 attached console output came from an older copy that supplied
`-Credential` to `Get-CimInstance`, which has no such parameter. This is not
fixed by waiting for the OS. The current code authenticates `Invoke-Command`
over WinRM and queries CIM locally inside that remote context instead.
Deploy the updated repository scripts, not the older attached text copy.

The process exits `0` for either successful terminal state, `1` for failure,
`2` for overall monitoring timeout, and `3` for unconfirmed final validation.
Neither observer timeout stops Server B or relaunches Setup.

## 4. Target Kickoff Script

File: `ServerB-Target/Start-TargetUpgrade.ps1`

### 4.1 Bootstrap and helper behavior

The script creates its ProgramData directories before performing checks. Its
master log receives a timestamp unique to this invocation.

The script requires and dot-sources `OSUpgradeStatus.ps1`; the recurring
monitor loads the same file. The helper is the sole implementation of typed
registry access, status snapshots, atomic JSON replacement, weighted progress,
high-water enforcement, sequence numbers, and reboot evidence.

The phase-to-stage mapping is:

```text
Phase 1       -> Stage 1/3: Pre-Upgrade Assessment
Phase 2       -> Stage 2/3: Backup
Phase 3-7     -> Stage 3/3: Windows Setup Execution
Phase 99      -> Stage 3/3: Windows Setup Execution (Rolled Back)
```

The caller supplies local phase progress (local stage progress for prechecks
and backup). `Set-Phase` maps it into the fixed phase range and refuses to lower
overall progress. A phase counter resets at the next phase instead of inheriting
Downlevel 100. Late in-progress writers cannot overwrite a terminal result or
regress a confirmed phase; a rollback hook can still report failure.
When no new number exists, it carries the prior sample and its source/timestamp
forward. Status changes still receive a new sequence and status timestamp.

`Enable-BackupPrivilege` uses Win32 token APIs to enable `SeBackupPrivilege`
and `SeRestorePrivilege`. It checks both the API result and error 1300 because
`AdjustTokenPrivileges` can return true even when the token was not assigned
the requested privilege.

### 4.2 Local stale-state protection

The target reads prior phase/status, process activity, and Panther log age. If
an in-progress attempt still looks alive, or has already reached Setup, it
throws immediately. An unresolved Setup attempt is not auto-cleaned just
because its process disappeared.

Otherwise it removes old task registrations, registry state, and marker files.
It renames an old `$WINDOWS.~BT` folder rather than recursively deleting it.
The new run then writes Phase 1, Status `InProgress`.

### 4.3 Precheck accumulator and percentage

`$hardFailures`, `$warnings`, and `$preCheckLog` are separate collections.
`Add-PreCheckResult` performs four operations for every completed check:

1. Add a formatted line to the dedicated report.
2. Log PASS, WARN, or FAIL.
3. Add warnings or failures to their respective aggregate.
4. Increment the completed-check count and publish `done / 16 * 100`.

A FAIL does not throw at the check site. This guarantees that the operator gets
all detected blockers in one run.

### 4.4 Detailed prechecks

**Domain controller:** `Win32_ComputerSystem.DomainRole` values 4 and 5, or an
installed AD DS role, cause a blocking failure. Inability to determine the
role also blocks.

**Failover cluster:** an installed Failover-Clustering feature or running
`ClusSvc` blocks. A detection exception also blocks.

**Free space:** `Get-PSDrive` reads free bytes on the actual system-drive
letter. The value is converted to GB and compared with `MinFreeSpaceGB`.

**Disk dirty bits:** `fsutil dirty query` checks every enumerated local fixed
NTFS volume, including mounted volumes without a drive letter. The system
volume must be included. Localized output can use the typed
`Win32_Volume.DirtyBitSet` value. A dirty volume, failed command, or unknown
result blocks the upgrade. No `dirty set`, dirty-bit clearing, CHKDSK repair, or
automatic reboot is performed; repairs require an approved maintenance action.

**Pending reboot:** the code checks the CBS `RebootPending` key, Windows Update
`RebootRequired`, and `PendingFileRenameOperations`. All findings block by
default. `-SkipPendingFileRenameCheck` removes only queued rename/delete
operations from the blocking decision, with an explicit WARN/Skipped record.
CBS and Windows Update still block, as do unreadable registry queries. Queue
entries are never cleared, including under the bypass.

The shared helper and the read-only `Test-UpgradeReadiness.ps1` retain
`RebootPending`, `Reasons`, and `Operations` as observed facts. The new
`UpgradeBlocked` and `BlockingReasons` reflect the effective decision after
the explicit bypass. Therefore `RebootPending=true, UpgradeBlocked=false`
is possible and is reported as bypassed, not as a clean reboot state.

**DISM:** `Dism.exe /Online /Cleanup-Image /ScanHealth` output is captured in a
separate log. An explicit no-corruption phrase passes. A recognized corruption
phrase blocks. Unknown output or execution failure warns.
Only `/ScanHealth` is executed, before SFC. `/RestoreHealth` appears only in
manual remediation guidance; no repair task is launched after SFC by these
scripts. Later `Get-WindowsImage` metadata queries and installation of the
Windows Server Backup feature use Windows servicing, but are not a scripted
DISM repair. This sequence is intentionally unchanged.

**SFC:** `sfc.exe /scannow` output is saved. The script also scans recent CBS
lines for scan-period `[SR]` corruption entries. A clean SFC summary passes.
Either repaired or unrepaired corruption blocks so the operator must verify a
subsequent clean scan. Inconclusive execution warns.

**ISO resolution:** `Get-OrMountIso` requires the folder and at least one ISO.
When several exist, the first alphabetically is used. It queries that exact
image with `Get-DiskImage -ImagePath`; an attached image is reused. Otherwise
it mounts the image and waits up to 15 seconds for a drive letter.

**Edition/flavor match:** the code reads current `EditionID` and
`InstallationType`. It enumerates WIM/ESD indices, then requests full metadata
for each index. Both edition and installation type must match, preventing a
Desktop Experience system from selecting the Core image with the same edition
ID. The matching index is saved in memory for `/ImageIndex`.

**Target build:** the third component of the selected image version becomes
`TargetBuild`. It must be numerically greater than the installed build. Equal
or older media blocks a repair or downgrade attempt.

**Activation:** a Windows `SoftwareLicensingProduct` with a partial key and
LicenseStatus 1 passes. Any other result warns and records the pre-upgrade
license state; activation does not technically block Setup.

**Patch currency:** a background job runs the Windows Update Agent search with
a 60-second limit. Pending updates normally block. If WUA fails or times out,
the newest `Get-HotFix` date is compared with `MaxPatchAgeDays`. The lab switch
changes a detected patch blocker to a warning.

**VMware Tools:** VMware hardware requires the registry installation, a parsed
version at or above the minimum, and a running `VMTools` service. Hyper-V and
non-VMware machines pass as not applicable.

**RDS Session Host licensing:** when the role exists, configured CAL servers
are queried in separate 15-second jobs. Their builds are compared with the
target build. This always reports WARN because remote reachability and CAL
installation cannot be proven reliably here. When the RDS Session Host role is
not installed, the check reports a not-applicable PASS and counts as one
completed check.

**Profile inventory:** `Win32_UserProfile` counts all registered profiles, with
separate user (`Special=false`), system/special, total, and loaded-user counts.
This counts profiles, not account objects or every directory under `C:\Users`.
It includes local, domain, and orphaned user profiles returned by that provider.
The counts and duration-risk note go to the console, precheck report, registry,
status JSON, mirror, and final summary. A per-profile CSV is written to the
target logs and copied into the run's backup folder for retention.
**Profile counts never block the upgrade, including counts above 25.** Every
successful inventory reports WARN with the actual non-special user count:

> Detected X user profiles on the target server. Systems with a higher number
> of user profiles may experience increased upgrade time due to additional
> profile migration and processing activities during setup.

The same result includes the loaded/system/total counts and CSV location.
An unavailable inventory or CSV write failure is explicitly reported as a
non-blocking warning; an unknown count is not fabricated as zero. The removed
`UserProfileCountCheckStatus` / `UserProfileCountLimit` fields and count-gate
summary are no longer published. `-SkipUserProfileCountCheck` remains accepted
for compatibility, logs that it is deprecated, and changes nothing: inventory
and warnings still run. The separate orphan-account and other safety gates
remain unchanged. No profiles are removed automatically.

**Orphaned profiles:** each `S-1-5-21-*` ProfileList SID is translated to an
NT account. Translation failure means the registry profile no longer maps to a
live account. Confirmed orphans block. An inability to evaluate the registry
warns instead of blocking.
`-SkipOrphanedProfileCheck` bypasses SID resolution and this gate only, with an
explicit WARN/Skipped record. It defaults off, does not run remediation, and
does not skip the independent profile inventory or disk health checks.

For confirmed orphans, the script writes a separate remediation script beside
the staged target script. That generated script is self-discovering, requires
elevation, confirms registry deletion, separately confirms optional profile
folder deletion, rejects dangerous folder paths, and escalates deletion from
`Remove-Item` to junction-safe `rd`, then ownership/ACL repair. Generation does
not execute remediation.

### 4.5 Precheck gate

The dedicated report is written under `BackupRoot` when its drive exists,
otherwise under ProgramData logs. If `$hardFailures` is nonempty, Phase 1 is
set to `Failed`, all reasons are joined with ` | `, and the script throws.

No backup or Setup launch occurs after that throw. Note, however, that the ISO
may already have been mounted during the ISO precheck; some failure messages
claim nothing was mounted even though this ordering allows a mount.

### 4.6 Backup folder and progress

The script rejects a `BackupRoot` whose qualifier equals the system drive. It
creates `BackupRoot\RunStamp`, saves that path in `BackupFolder`, and starts an
independent eight-task progress counter.

Individual backup operations are mostly wrapped in local catches. Their
failure logs a warning but still increments the task counter, because the task
was attempted. A failure creating or using the overall backup root escapes the
outer try, sets Phase 2 to Failed, and terminates.

The tasks are:

1. Export all services and their status/start type to
   `Services_PreUpgrade.csv`.
2. Enable backup privileges and run `reg.exe save` for SYSTEM, SOFTWARE, SAM,
   SECURITY, and `HKU\.DEFAULT` into real hive files. The added artifact is
   `Registry\HKU_.DEFAULT.hiv` inside the run's backup folder. This backs up
   the registry hive, not the `C:\Users\Default` profile template. A save
   failure retains the existing per-hive WARN policy and is never logged as
   a successful save.
3. Mirror Local Group Policy and GroupPolicyUsers with `robocopy`.
4. If supplied, run `LGPO.exe /b` and parse machine/user Registry.pol files.
5. Export local security policy with `secedit.exe`.
6. Generate an HTML Resultant Set of Policy report with `gpresult.exe`.
7. If this target is an RDS License Server, hot-copy its LServer database.
8. Unless skipped, install Windows-Server-Backup when missing and run
   `wbadmin start systemstatebackup` against the backup volume.

`wbadmin` cannot target a local subdirectory. Its data therefore lands under
`<drive>:\WindowsImageBackup\<computer>`. The per-run folder gets a pointer
file and the registry receives `SystemStateBackupPath`.

### 4.7 Baseline and companion deployment

After backup, the script records source caption, source build, source edition,
start time, ISO path, and JSON path. If media inspection did not already set a
target build, it attempts a fallback read of image index 1.

The shared status helper, status engine, cleanup script, CMD hooks, and optional LGPO executable are
copied from staging into `C:\ProgramData\OSUpgradeAutomation\Scripts`. This is
the stable path used across reboots.

### 4.8 Task registration

`OSUpgradePhaseMonitor` runs the status engine as SYSTEM every minute for up to
three days. It also fires at startup and for Kernel-General Event 12 or EventLog
Event 6005. `MultipleInstances IgnoreNew` prevents overlapping invocations.
`LastBootUpTime` is the unique reboot identity; Events 12/6005 only corroborate
the boot and can safely trigger duplicate refresh attempts.
The task has a ten-minute execution limit so a hung invocation cannot suppress
future runs indefinitely. A separate monitor mutex serializes scheduled and
direct hook invocations; the status writer has its own publication mutex.

`OSUpgradeRebootWatcher` uses a Task Scheduler event trigger for User32 Event
ID 1074. Its best-effort action records a restart request while preserving the
current phase. Arbitrary restart events, outage durations, and WinRM/SMB
availability are not sufficient proof of Safe OS.

`OSUpgradeAutoCleanup` runs once at kickoff plus `RetentionDays`. The timer is
from kickoff, not completion. Cleanup later checks whether status is terminal.

### 4.9 Setup arguments and launch

Before launch, the script enters Phase 3. Setup receives:

```text
/Auto Upgrade
/Quiet
/DynamicUpdate Disable
/Telemetry Disable
/Compat IgnoreWarning
/PostOOBE <setupcomplete.cmd>
/PostRollback <setuprollback.cmd>
/PostRollbackContext System
/ImageIndex <matched image>
```

`/DynamicUpdate Disable` prevents Setup downloading new content. `/Telemetry
Disable` avoids network-dependent OneSettings behavior. `/Compat IgnoreWarning`
ignores warnings, not hard compatibility blocks. `/ImageIndex` removes
ambiguity on multi-image media. `/PostRollbackContext System` ensures rollback
reporting remains unattended and does not depend on a signed-in user.

The launch task runs as SYSTEM/Highest and is triggered immediately. The script
also calls `Start-ScheduledTask`, then polls process names for up to 60 seconds.
Failure to observe a process is only a warning; successful task registration is
treated as a successful handoff.

With controlled reboot, `/NoReboot` is added. The script waits until all Setup
processes disappear, waits another 60 seconds, and invokes `Restart-Computer`.
Without that switch, Windows Setup owns all restarts.

The target kickoff script then exits. From this point, tasks, hooks, registry,
JSON, and Windows Setup carry the workflow.

## 5. Status and Validation Engine

File: `ServerB-Target/Update-UpgradeStatus.ps1`

### 5.1 Invocation model

This file accepts only the internal `RebootInitiated` switch. It reads the JSON
path and all run context from the shared registry. It can be invoked by the
recurring/startup/event SYSTEM task, Event 1074 watcher, OOBE hook, or rollback
hook. Each invocation is short-lived and recomputes current state from durable
evidence.

It dot-sources `OSUpgradeStatus.ps1`, exactly as the kickoff script does. In
addition to registry and JSON, the shared publisher appends every transition to:

```text
D:\UpgradeBackup\<run>\OSUpgradeProgress.log
```

### 5.2 Measured percentage sources

`Get-MoSetupVolatileProgress` reads Microsoft's SetupProgress registry value.
It handles either a byte array or numeric representation and accepts only
values from 0 through 100.

`Get-SetupProgressPercent` accepts only MoSetup's documented
`SetupProgress`. `ChildCompletion` and percentage-like text in `setupact.log`
are intentionally excluded because they are scoped implementation details, not
reliable end-to-end counters. MoSetup itself is used only within the current
phase's range, never as proof of completion.
When MoSetup is absent, callers preserve the last sample and mark it
`CarriedForward`.

`Get-SetupPhaseEvidence` separately recognizes actual `SP Executing phase [...]`
and `OPERATIONTRACK ExecuteOperations: Start execution phase ...` events from
the current run, using `SetupLaunchTimeUtc` to reject old attempts. Queued
operations and `Add phase` lines are not execution evidence. Both Panther log
locations are inspected after boot/target-build observations or while
investigating a stopped/rolled-back upgrade. The large growing log is not
repeatedly scanned during normal Downlevel polling. File length/write-time signatures avoid rescanning
unchanged logs; the earliest confirmed start per phase is persisted in
`SetupPhaseHistory`. Safe OS can be recovered retrospectively even though this
solution has no monitor running inside WinPE.
Windows PowerShell 5.1's non-enumerated `ConvertFrom-Json` arrays are explicitly
normalized, including legacy nested arrays/remoting lists. Empty history is
`[]`, not `[[]]`. Invalid records are reported and never printed as blank
phases; damaged cached history forces a fresh evidence scan.

### 5.3 Post-upgrade validation

`Invoke-PostUpgradeValidation` first requires registry and live OS builds to
match the expected target. A build mismatch is Failed, never a successful
upgrade with warnings. An unavailable core query leaves validation pending
with `MonitorLastError` for retry; it does not publish false success.
Noncritical edition/licensing/service issues are then accumulated.

It checks current build against target build and current edition against source
edition. It compares pre/post activation and writes a complete human-readable
recommendation for every combination.

It directly checks `RpcSs`, `EventLog`, and `Winmgmt` are running.

For the full service comparison, the pre-upgrade CSV becomes a name-indexed
baseline. A missing service or stopped service is an attention item only when
it was previously Running and Automatic. Per-user suffixed services and known
self-managing Windows services are informational. New services are also
informational. The detailed report and both counts are saved to the backup
folder and registry.

No accumulated issue produces Status `Completed`. Any issue produces
`CompletedWithWarnings`. Both write measured 100 percent and unregister the
monitor, reboot watcher, and Setup launch tasks. The cleanup task remains so it
can perform retention cleanup later.

### 5.4 Main decision order

Order is important:

1. Read current, source, and target builds plus prior phase/status.
2. If already terminal and no rollback marker exists, remove active tasks and
   return.
3. If the rollback marker exists, set Phase 99/Failed, copy SetupDiag results
   when available, remove active tasks, and return.
4. On a restart notification, record the request without changing the phase.
   Otherwise update boot evidence and current-run Setup phase history.
5. If the OOBE marker exists and status is nonterminal, set Phase 6 when needed,
   validate, and return. A later invocation resumes an interrupted Phase 7
   validation without regressing to Phase 6.
6. On the target build, clear Setup/OOBE flags plus no Setup process can also
   trigger validation when the hook was missed, including an interrupted Phase 7.
7. On the source build, track Setup liveness; a prior restart request is not
   an exemption from the missing-process deadline.
8. Otherwise identify First Boot/OOBE from live state and execution evidence,
   or report an unexpected-build failure.

### 5.5 Downlevel branch

When a Setup process exists, the engine captures a Panther tail for diagnostics
and publishes Phase 3. Only MoSetup can update the numeric value.

A missing Setup process on the source OS immediately publishes an ATTENTION
note and starts a persistent ten-minute grace period, even if Phase 4 or
`ExpectedDisconnect` was stored by an older watcher. If the process resumes,
the timer clears. Otherwise the run becomes Failed with its last phase,
boot/reset evidence, task result, and diagnostic paths. A reset that leaves
the target unreachable is reported by Server A's stale-status watchdog;
network loss alone does not prove that Setup failed.

### 5.6 New-build branch

If `SystemSetupInProgress=1` and no OOBE marker exists, the engine publishes
Phase 5. MoSetup remains the only numeric source; otherwise the prior verified
value is carried forward.

If the OOBE marker exists, it publishes the deterministic 100% Setup milestone
(95% overall) at Phase 6 and immediately validates.

If both Setup and OOBE flags are present and zero, no Setup process remains,
and the live build is the target, the engine can validate without the marker.
Unknown flags are not zero. Interrupted Phase 7 validation is retried on either
completion-evidence path.

## 6. Windows Setup Hook Files

### 6.1 `setupcomplete.cmd`

Windows Setup requires the exact filename for `/PostOOBE`. The file disables
command echo, writes the current date/time into `postoobe.marker`, runs the
status engine synchronously, and returns exit code zero.

The marker is durable evidence that the hook fired. The immediate PowerShell
call avoids waiting up to one minute for the recurring monitor.

### 6.2 `setuprollback.cmd`

This is structurally identical but is registered with `/PostRollback`. It
writes `rollback.marker`, invokes the status engine, and returns zero. The
engine sees rollback before normal build-based logic and writes Phase 99.

## 7. Cleanup Script

File: `ServerB-Target/Remove-UpgradeArtifacts.ps1`

The script reads Status and StatusJsonPath before deleting the registry. Its
terminal allow-list is `Completed`, `CompletedWithWarnings`, and `Failed`.

Without `-Force`, a known nonterminal state causes cleanup to skip all data
deletion. It unregisters only the one-time cleanup task so it does not keep
firing.

For an allowed or forced cleanup, it attempts each operation independently:

1. Unregister all four task names.
2. Delete the configured status JSON.
3. Delete the shared registry root.
4. Delete `C:\ProgramData\OSUpgradeAutomation`.

Failures are printed but do not stop later cleanup steps. The currently
executing cleanup script can keep part of its own directory open, so an
incomplete ProgramData removal is explicitly tolerated.

The script never removes `D:\UpgradeBackup` or `WindowsImageBackup`.

## 8. End-to-End Success Trace

1. Operator starts the orchestrator on Server A.
2. Server A validates files and chooses a working WinRM transport.
3. It determines this is not a live or completed prior run.
4. It copies target files and invokes the target kickoff script.
5. Server B clears stale inactive state and enters Phase 1.
6. All prechecks execute and their results are aggregated.
7. The hard-failure list is empty, so Server B enters Phase 2.
8. Eight backup tasks are attempted; Stage 2 reaches 100 percent and overall
   progress reaches 25 percent.
9. Source/media data and stable companion files are recorded.
10. The monitor, reboot watcher, cleanup, and Setup tasks are registered.
11. Server B enters Phase 3 and starts the Setup task as SYSTEM.
12. The remote kickoff job returns; Server A closes its PSSession.
13. The status task maps Downlevel MoSetup progress into overall 25-50.
14. Event 1074 records a restart request without asserting Safe OS.
15. During WinPE, all target channels can be unavailable; Server A keeps its
   local JSON mirror readable and marks the producer snapshot carried forward.
16. At startup, Event 12/6005 trigger a refresh; `LastBootUpTime` increments
   the unique reboot count and both events are recorded as corroboration.
17. On the target build, the status task can observe Phase 5 and recovers any
    missed Safe OS/First Boot starts from the actual Setup execution log.
18. Windows Setup executes `setupcomplete.cmd` after OOBE.
19. The marker causes Phase 6 at 95% overall followed immediately by validation.
20. Validation writes Phase 7 and 100% with a successful terminal status.
21. Server A waits for ActivePolling, confirms the build, prints the summary,
    and exits zero.
22. At retention time, cleanup deletes transient tracking artifacts but keeps
    backups.

## 9. End-to-End Precheck Failure Trace

1. Every check still executes.
2. Each blocker is appended to `$hardFailures`.
3. A complete report is written.
4. Phase 1 becomes Failed and the joined reasons are thrown to Server A.
5. Backup and Setup do not execute.
6. Server A prints remediation and returns without entering monitoring.

The ISO can already be mounted because media inspection is itself a precheck.

## 10. End-to-End Rollback Trace

1. Windows Setup encounters a failure after launch.
2. Windows restores the previous OS and invokes `setuprollback.cmd`.
3. The hook writes `rollback.marker` and invokes the status engine.
4. The engine copies SetupDiag results when present.
5. It writes Phase 99 and Status Failed while retaining the highest verified
   overall percentage and its original sample timestamp.
6. Server A receives that target-reported failure and exits one.

## 11. Timeout and Monitor Restart

An orchestrator timeout is not an upgrade failure. Server A exits two, but
Server B's Setup process, scheduled tasks, hooks, registry, and JSON remain.

When the same command is run again, unresolved Phase 3-or-later state or a
completed terminal record skips a second kickoff and resumes
monitoring/reporting. The Server A mirror is loaded from disk first, so its last
producer `RunId`, sequence, phase, and percentage remain available while the
target is still offline; `Observer.CacheState` is `RecoveredFromDisk` until a
fresh target snapshot arrives.

## 12. Files That Are Not Runtime Code

`PROJECT-NOTES.md` is design history and test findings. It is valuable context
but does not execute.

`ImprovementsRequired.md` is a requirement/backlog note. The current runtime
does not yet implement its requested `Get-ComputerInfo`, `systeminfo`, and
`ipconfig /all` inventory files or an explicit check that the connecting
operator is a member of Server B's local Administrators group. The current
target code still saves registry hives in addition to taking system state,
despite that note requesting system state instead of registry backup.

`Pather Path.txt` is troubleshooting reference text for Panther log locations.
It does not affect execution.

Files under `SKILLS` describe custom AI-agent behavior and are not loaded or
called by the OS upgrade scripts.