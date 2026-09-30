# OS Upgrade Automation — Project Context & Session Notes

## Reliability update - 2026-09-26

See [CHANGE-TRACKING.md](CHANGE-TRACKING.md) for the implementation plan,
specific fixes and reasons, safe test commands, verification evidence and
required lab acceptance checks. This section supersedes historical statements
below that describe accepting completion after repeated independent build-query
failures, assuming no prior attempt when state cannot be queried, or lacking a
WinRM status-data channel. The orchestrator now fails closed for uncertain
startup state and requires live build confirmation for success.

New assessment-only and monitor-only workflows support testing without starting
Windows Setup. These are not substitutes for a full recoverable lab upgrade;
assessment may write reports and temporarily mount media. See the change tracker
for exact flags and limitations.

New lab-only performance switch `-SkipDismScanHealthLab` skips only
`Dism /Online /Cleanup-Image /ScanHealth`. The named pre-check is still recorded
as `WARN` so assessment progress remains correct and the report explicitly says
component-store health was not validated. A separate lab-only performance
switch, `-SkipSfcScanNowLab`, skips `sfc /scannow` and its CBS.log analysis,
records WARN and explicitly leaves protected system-file integrity unverified.
The switches are independent. They may be combined for disposable functional
testing, but neither may be used for production acceptance or production
upgrades.

Assessment-only logging fix: `-PrecheckOnly` now logs its successful completion
with the target logger's supported `PASS` level. The earlier `SUCCESS` literal
was valid only in the Server A logger and caused a passed target assessment to
be returned as a failure. Retry command generation also recognizes Credential
by parameter name, preserving the literal `-Credential $cred` placeholder.

_Last updated: 2026-09-09 (orphaned-profile remediation expanded into three explicit options - per-SID commands, bulk copy/paste block, and a GENERATED ready-to-run Remove-OrphanedProfiles.ps1 on the target staging folder - plus a matching orchestrator failure banner branch; earlier same day: added automatic WinRM HTTPS/5986 fallback on Server A - previously every WinRM call hardcoded the HTTP/5985 default and a target with only a 5986 listener could never be reached; new -UseSSL / -SkipCertificateCheck switches. Previously: 2026-08-26 - added a 14th precheck, "Target media build is newer than current OS build" - hard FAIL, explicit customer decision - after a real TestVM2 run showed same-version media passes every existing check and launches a no-op repair-install; also fixed the SourceBuild==TargetBuild phase-detection stuck-at-Safe-OS bug and the stale cross-stage PercentComplete/PercentSource leak; added System State backup as backup task 8/8; enhanced the RDS Session Host CAL license server precheck; carried over the 2026-07-28 DISM/SFC revert-to-FAIL decision, the 2026-07-26 SFC/scannow + CBS.log check addition, orphaned-profiles hard FAIL + self-discovering cleanup script, and the 2026-07-24 GUI-percentage/task-count-based Stage 1/2 work)_

> **How to use this file**: In a new chat session, tell me to "read
> `PROJECT-NOTES.md` in OSUpgradeAutomation1 and continue" - that gives me
> full context on the architecture, decisions made, and bugs already fixed,
> without needing to re-explain everything from scratch.
>
> **Standing instruction**: this file is kept up to date after every
> significant change (new fix, new feature, new test result) - not just at
> the end of a session. If you notice it drifting out of sync with the code,
> ask me to refresh it.

## What this solution does
Automates and remotely monitors an in-place Windows Server OS upgrade:
- **Server A** (management machine) runs the orchestrator, which stages
  files onto Server B, kicks off the upgrade, and monitors progress through
  every reboot until completion.
- **Server B** (target server) runs the pre-checks, backup, ISO mount, and
  `setup.exe` launch, then tracks its own phase/progress locally.

## Architecture / who does what (for ServiceNow or any other remote-trigger integration)
Three scripts run ON Server B and own ALL phase/percent tracking - Server A
never computes progress itself, it only ever READS what Server B already
computed, via one of three independent channels (file share / registry-via-
CIM-DCOM / nothing-during-the-genuine-WinPE-blind-window):
- **`Start-TargetUpgrade.ps1`** (Server B) - runs prechecks + backup, then
  sets Phase 1 -> 2 -> 3 as it progresses through its own steps, before ever
  launching `setup.exe`. This is the ONLY phase/percent writer that runs
  synchronously as part of the kickoff call itself.
- **`Update-UpgradeStatus.ps1`** (Server B) - the actual phase/percent
  ENGINE for everything from Downlevel onward. Registered as a recurring
  2-minute Scheduled Task (`OSUpgradePhaseMonitor`) by `Start-TargetUpgrade.ps1`,
  PLUS invoked immediately by three
  event hooks: the Event-ID-1074 watcher task (`OSUpgradeRebootWatcher`,
  fires the instant a restart is initiated), and Windows Setup's own
  `setupcomplete.cmd`/`setuprollback.cmd` (`/PostOOBE`/`/PostRollback`
  hooks, mandatory-exact filenames per Microsoft). It writes every
  phase/percent update to BOTH the registry AND the JSON file - this is the
  single source of truth Server A always reads from. `PercentComplete` is
  paired with a `PercentSource` field. Stage 3 accepts only Microsoft's
  `mosetup\Volatile\SetupProgress` live telemetry (Downlevel, First Boot;
  carried forward
  unchanged during Safe OS/OOBE where no telemetry can exist) or, for Stage
  1/2 (Pre-Upgrade Assessment/Backup, which have no telemetry source of
  their own at all), a genuine task-count fraction ("N of M checks/tasks
  done") - a real measurement either way, never a fabricated milestone
  guess. `ProgressFreshness`, `ProgressUpdatedAtUtc` and
  `StatusUpdatedAtUtc` distinguish live/milestone/carried/terminal evidence
  without changing the original timestamp of a carried sample. A
  `PercentStage` field (internal bookkeeping, not exposed in the
  JSON) tracks which Stage the current `PercentComplete` belongs to, so the
  monotonic-never-decreases clamp only applies WITHIN a stage, never across
  a stage boundary (each Stage has its own independent 0-100 scale).
- **`Start-RemoteUpgradeOrchestrator.ps1`** (Server A) - a pure READER/
  monitor. Polls Server B every `-PollIntervalSeconds` (default 15s) via
  whichever channel answers (file share, then CIM/DCOM, then ping-only
  during the genuine WinPE blind window), renders `Write-Progress`, logs
  phase transitions, and prints a final summary banner (Status/Server OS/
  Build/services-comparison result) before exiting 0 (success) / 1 (failed)
  / 2 (timeout). **If this process is killed/closed, the upgrade on Server B
  is completely unaffected** - re-running it just resumes monitoring (with
  a liveness check to avoid falsely resuming a stale/dead attempt - see bug
  list below). This is the piece a ServiceNow-triggered remote call should
  invoke; it needs nothing of its own to survive between polls.

## File layout
```
OSUpgradeAutomation1/
├── ServerB-Target/                      (copied to & run ON Server B)
│   ├── Start-TargetUpgrade.ps1          - prechecks, backup, ISO mount, setup.exe launch (via Scheduled Task)
│   ├── Update-UpgradeStatus.ps1         - 5-min scheduled task: phase/percent tracker + post-upgrade validation
│   ├── Remove-UpgradeArtifacts.ps1      - retention-based cleanup (registry/JSON/scheduled tasks)
│   ├── setupcomplete.cmd                - Windows Setup /PostOOBE hook (filename is mandatory-exact)
│   ├── setuprollback.cmd                - Windows Setup /PostRollback hook (filename is mandatory-exact)
│   └── LGPO.exe                         - OPTIONAL, user-supplied (Security Compliance Toolkit) - enables portable Local GPO backup
└── ServerA-Orchestrator/
    └── Start-RemoteUpgradeOrchestrator.ps1  - stages files, kicks off upgrade (unless already in progress), monitors via Write-Progress
```

## Why phase transitions can appear to "skip" (Downlevel -> Completed with
no visible Safe OS/First Boot/OOBE in between) - and whether the logic to
track them exists anyway
This IS expected on fast/lightweight VMs, and it's a **visibility**
limitation of Server A's 15-second polling snapshot - NOT a gap in the
underlying tracking logic, which DOES fully exist and fire for every phase:
- Phase 4 (Safe OS) can be set INSTANTLY by the Event-1074 watcher, but on
  a small/fast VM the WinPE apply + reboot + First Boot + OOBE can all
  complete within a single short WinRM-down window (seen: ~17-40 seconds).
  Server A only re-polls every 15s and only WHEN WinRM is reachable again -
  if by the time it reconnects the machine has already raced past Safe
  OS/First Boot straight to OOBE, Server A's snapshot simply never landed
  on those intermediate values.
- Phase 6 (OOBE) -> Phase 7 (Completed) is the most likely to be missed
  entirely: `setupcomplete.cmd` calls `Update-UpgradeStatus.ps1` directly
  (not waiting for the 5-min schedule), which sets Phase 6, then
  IMMEDIATELY calls `Invoke-PostUpgradeValidation` in the same execution,
  which sets Phase 7 a few hundred milliseconds later - both writes happen
  faster than Server A's 15-second poll interval, so Server A's snapshot
  can easily only ever see Phase 7.
- **The full-fidelity record still exists** even when Server A's live view
  skips a step: `Update-UpgradeStatus.log` on Server B (and now also
  `D:\UpgradeBackup\<run>\OSUpgradeProgress.log` - see below) records EVERY
  phase transition with a timestamp, so the true Downlevel-to-Completed
  timeline (or exactly which phase a failure occurred at) is always
  reconstructable after the fact even if the live console view skipped it.
- **Overall percentage IS tracked spanning all phases** (not per-phase
  only): `PercentComplete` in the registry/JSON is a single 0-100 value
  that advances monotonically across the whole run (20/25 Downlevel ->
  40/55 Safe OS -> 60-70 First Boot -> 95 OOBE -> 100 Completed/0 on
  Rollback), and on failure `Set-Phase -Phase 99 -PhaseName "Rolled Back"`
  is written with `Notes` describing exactly why (SetupDiag results path
  included) - so "failed at phase X" reporting already works today; the
  orchestrator's final banner (see below) now also explicitly prints "Failed
  at phase: ..." for this reason.

## New features added for change-record / ServiceNow reporting (2026-07-18)
- **Post-upgrade services comparison**: `Start-TargetUpgrade.ps1` snapshots
  every service's Name/DisplayName/Status/StartType to
  `D:\UpgradeBackup\<run>\Services_PreUpgrade.csv` before touching anything.
  `Update-UpgradeStatus.ps1`'s post-upgrade validation (Phase 7) diffs the
  live post-upgrade state against that baseline, writes a full verbose diff
  to `D:\UpgradeBackup\<run>\Services_PostUpgrade_Comparison.txt`, and sets
  `ServicesComparisonResult` = `Consistent` / `RequiresAttention` /
  `NotAvailable` (a service that was Running before and isn't after is what
  triggers `RequiresAttention`; pure StartType-only changes are recorded but
  not attention-worthy by themselves). Both the result and the report path
  travel to Server A over both status channels (file share JSON + CIM/DCOM).
- **Durable mirrored progress log**: every `Set-Phase` call in
  `Update-UpgradeStatus.ps1` now ALSO appends the same phase/percent/notes
  line to `D:\UpgradeBackup\<run>\OSUpgradeProgress.log` - a second,
  never-auto-deleted copy of the full Downlevel-to-Completed/Rolled-Back
  timeline, alongside the existing `C:\ProgramData\OSUpgradeAutomation\Logs`
  copy (which DOES get purged by `Remove-UpgradeArtifacts.ps1` after
  `-RetentionDays`).
- **Richer final summary banner** on Server A: now explicitly prints
  `OS upgrade Status: Success/Fail`, `Server OS`, `Build`, and
  `Post-upgrade services: Consistent/RequiresAttention/NotAvailable (report
  path)` before exiting - see the console-hang fix below for why it wasn't
  reliably reaching this point before.

## Registry/task cleanup - which script does what, and when
Two DIFFERENT things happen, at DIFFERENT times, and it's important not to
conflate them:
1. **Immediately** upon reaching ANY terminal state (Completed/
   CompletedWithWarnings/Failed/RolledBack), `Update-UpgradeStatus.ps1`
   itself unregisters the 3 recurring/event-driven Scheduled Tasks
   (`OSUpgradePhaseMonitor`, `OSUpgradeRebootWatcher`, `OSUpgradeSetupLaunch`)
   so they stop firing - but it does **NOT** delete the registry key, the
   JSON file, or anything under `D:\UpgradeBackup`. Status stays fully
   readable/inspectable indefinitely after completion.
2. **`-RetentionDays` days AFTER KICKOFF** (not after completion - the timer
   starts when `Start-TargetUpgrade.ps1` registers the `OSUpgradeAutoCleanup`
   task at the very start of the run), `Remove-UpgradeArtifacts.ps1` runs
   automatically and deletes: the JSON status file, the entire
   `HKLM:\SOFTWARE\OSUpgradeAutomation` registry key, and the
   `C:\ProgramData\OSUpgradeAutomation` folder (logs/markers/staged
   scripts) - it refuses to delete anything if `Status` is still
   non-terminal (safety check, override with `-Force`). **`D:\UpgradeBackup`
   is intentionally NEVER touched by this cleanup** - it's the durable
   change-record backup, not disposable monitoring metadata.
3. Can also be run manually/on-demand at any time (e.g. once a change
   ticket is verified and closed): `powershell.exe -File
   "Remove-UpgradeArtifacts.ps1" -Force`.

## Console-hang-after-Completed bug (found & fixed 2026-07-18)
After `Status=Completed`/`CompletedWithWarnings` is detected, the
orchestrator does one EXTRA independent re-check - a plain WSMan-based
`Get-CimInstance ... Win32_OperatingSystem` call from Server A - before
declaring final success, specifically to confirm the live build number
matches. That extra CIM call's failure path was **completely silent** (no
log line at all), so if it kept failing for any reason (DCOM/WMI-specific
issue distinct from plain WinRM, which was already confirmed reachable),
the console just sat at 100% Completed forever with zero visible
explanation - exactly what was observed. **Fix**: the catch block now logs
every failed attempt, and after 8 consecutive failures (~2 minutes at the
default poll interval) falls back to trusting Server B's own
already-build-verified `Status` (which itself is never set to a terminal
value until `Update-UpgradeStatus.ps1` confirms `currentBuild -eq
targetBuild` locally) rather than looping forever.

## Key design decisions
- **Dual status channel on Server B**: every phase/percent update is written
  to BOTH the registry (`HKLM:\SOFTWARE\OSUpgradeAutomation`) AND a JSON file
  (`D:\upgrade_status.json`), so Server A can read status via either the
  admin share (`\\ServerB\D$\upgrade_status.json`, no WinRM needed) or a
  DCOM-based CIM/WMI registry read (also WinRM-independent) as a fallback.
- **Phase model** (kept consistent across all scripts) - see "Full phase list"
  below for descriptions of each: `1` Pre-Upgrade Assessment · `2` Backup ·
  `3` Downlevel · `4` Safe OS (WinPE, blind window) · `5` First Boot ·
  `6` Second Boot/OOBE · `7` Completed · `99` Rolled Back/Failed.
- **setup.exe is launched via a Scheduled Task, not `Start-Process`**:
  `Start-TargetUpgrade.ps1` runs inside Server A's `Invoke-Command -Session`
  (WinRM) remote runspace, and a plain child process there inherits a
  restricted, non-interactive window station - Windows Setup can silently
  fail/hang when launched that way. It's instead handed off to a locally
  registered, immediately-triggered Scheduled Task (`OSUpgradeSetupLaunch`,
  SYSTEM/Highest), decoupling it from the transient WinRM token (same
  pattern SCCM/MDT use).
- **Resume detection on the orchestrator**: before staging/kicking off
  anything, `Start-RemoteUpgradeOrchestrator.ps1` reads Server B's current
  `Phase`/`Status` first. If an upgrade is already `InProgress`, it skips
  straight to the monitoring loop instead of re-staging files and
  re-invoking `Start-TargetUpgrade.ps1` (which has no re-entrancy guard of
  its own) - safe to just re-run the orchestrator after a dropped session.
- **Auto stale-attempt cleanup on Server B**: `Start-TargetUpgrade.ps1`
  itself checks for leftover state from a prior run before every new
  attempt. `Status=InProgress` alone is NOT trusted (a prior run can
  self-cancel without ever reaching a terminal status - see bug #11 below) -
  it instead looks for real activity evidence (a live `setup`/`SetupHost`/
  `SetupPrep` process, or a `setupact.log` written to within the last 5
  min - real Setup activity writes to that log every few seconds, so a
  longer gap is actually evidence of a dead attempt, not an active one).
  If genuinely active, it refuses to start a second attempt
  (`throw`). If not, it automatically unregisters the 4 scheduled tasks,
  clears the registry key, removes stale OOBE/rollback markers, and renames
  away any leftover `$WINDOWS.~BT` - then proceeds with a clean run.
- **Progress % sources**: Stage 1/2 use measured task-count milestones. Stage
  3 uses only Microsoft-documented
  `HKLM:\SYSTEM\Setup\mosetup\Volatile\SetupProgress`; when absent, the last
  verified sample and its original timestamp are carried forward. Panther
  logs remain diagnostic evidence and are not parsed for percentages.
- **WinRM disconnect handling on Server A**: explicit `Test-WSMan`-based
  `Mode` state machine (`ActivePolling` / `Heartbeat` / `Offline`) with clear
  transition logging ("WinRM connectivity LOST/RESTORED..."). Final success
  is only declared once `Mode -eq "ActivePolling"` again (not just ping).
- **Ping/ICMP is a best-effort signal only, never a hard gate**: some
  environments block ICMP entirely via firewall policy, in which case ping
  would NEVER succeed even though the target is fully up and
  WinRM-reachable. Both the initial pre-flight check and the main
  monitoring loop's `Get-UpgradeStatus` always attempt WinRM/file-share/
  DCOM regardless of the ping result - `Offline` is only ever reported when
  literally none of ping/WinRM/file/DCOM answer. (Fixed 2026-07-19; ping
  failure used to short-circuit everything else, including the pre-flight
  check throwing before the orchestrator could even start.)
- **WinRM transport is auto-resolved: HTTP/5985 first, then HTTPS/5986**
  (added 2026-09-09). WinRM does no protocol/port negotiation of its own -
  a cmdlet without `-UseSSL` talks 5985 and never retries over 5986 - so
  previously a target whose ONLY open listener was 5986 failed at the
  pre-flight `Test-WSMan` gate and could never be upgraded or monitored.
  Section 1b now resolves the transport ONCE up front via bounded probes
  (each wrapped in a `Start-Job`/`Wait-Job` timeout, since neither
  `Test-WSMan` nor `New-PSSession` has a native per-call timeout against a
  firewalled port), stores it in `$script:WinRMTransport`, and every WinRM
  consumer honours it: `$sessionParams` (built by `Get-WinRMSessionParams`,
  used by both `Invoke-Command` and `New-PSSession`), the monitoring loop's
  `Test-RemoteWinRM` liveness probe, and the final WSMan-based
  `Get-CimInstance` build re-confirm (which needs a real `New-CimSession`
  with `New-CimSessionOption -UseSsl`, since `Get-CimInstance -ComputerName`
  alone always targets 5985). New switches: `-UseSSL` (skip the 5985 probe
  entirely) and `-SkipCertificateCheck`. **Security note**: the HTTPS probe
  performs FULL certificate validation by default and the script NEVER
  silently downgrades to unvalidated TLS - the cert-bypass transport is
  only ever attempted when `-SkipCertificateCheck` is explicitly passed,
  and logs a WARN when used. `Test-WSMan` has no `-SessionOption`
  parameter at all (verified against the installed cmdlet), so the
  cert-bypass probe has to open and immediately dispose a real
  `New-PSSession -UseSSL -SessionOption (New-PSSessionOption -SkipCACheck
  -SkipCNCheck -SkipRevocationCheck)` instead.
- **Timeout model - no per-phase failure inference, ever**: the orchestrator
  NEVER declares a failure from elapsed time or a transient probe failure
  by itself. The only two things that end monitoring are (a) Server B's
  own self-reported `Status=Failed` (relayed, not inferred), or (b) the
  overall `-TimeoutMinutes` (default 180) elapsing, which reports a
  neutral `Timeout` outcome - explicitly NOT `Failed` - telling you to just
  re-run to resume monitoring, since the upgrade may still be legitimately
  in progress. On top of that blanket timeout, `-PhaseStallWarningMinutes`
  (default 45) adds an escalating, purely INFORMATIONAL `WARN` if a single
  phase (e.g. Safe OS or First Boot) runs unusually long without changing -
  fires at 1x/2x/3x... the threshold, never stops or alters monitoring,
  and exists solely to avoid being blind for the full 180-minute window
  with zero signal either way. This deliberately avoids any race condition
  where the script could declare an issue before the target has had a fair
  chance to come back up.
- **Re-running after a Timeout exits the process entirely** - `-TimeoutMinutes`
  elapsing doesn't pause anything, it ends the PowerShell process (`exit 2`).
  "Re-run to resume monitoring" means literally invoking the same command
  again, starting a brand-new process. Its resume-detection (Section 2b)
  checks Server B's real state first: if still genuinely `InProgress`, it
  skips straight to a fresh monitoring loop; if it ALREADY reached a
  terminal `Completed`/`CompletedWithWarnings` state (e.g. it finished on
  Server B during the gap between the old process timing out and the
  manual re-run), it also skips re-staging/re-kickoff entirely and just
  reports the existing outcome on the next poll - re-launching `setup.exe`
  on an already-upgraded server would be pointless. Only a genuinely
  `Failed`/stale prior attempt falls through to a real fresh retry.
- **Retention/cleanup**: `Start-TargetUpgrade.ps1 -RetentionDays N` registers
  an `OSUpgradeAutoCleanup` scheduled task that runs `Remove-UpgradeArtifacts.ps1`
  once, N days after kickoff - only deletes if status is terminal.
- **Graceful failure on Server A**: pre-check failures on Server B are never
  re-thrown as raw exceptions on Server A - they're rendered as a clean
  banner, with SPECIFIC extra remediation steps when the cause is a pending
  reboot (reboot + re-run exact command).

## Known bugs found & fixed during lab testing (TestVM1)
1. **`Get-DiskImage` with no `-ImagePath`** used to check for an
   already-mounted ISO → `-ImagePath` is mandatory, so PowerShell prompted
   interactively and hung. **Fix**: always call with the specific candidate
   ISO path; `.Attached` tells you if it's already mounted.
2. **`Get-WindowsImage -ImagePath <wim>` without `-Index`** only returns a
   lightweight listing - `EditionId`/`Version` are blank unless `-Index N` is
   also passed per image. Caused false "edition not present on this media"
   failures with a blank "Available editions:" list. **Fix**: enumerate
   indices first, then re-query each one with `-Index` for real metadata.
3. **CRITICAL - `$Args` parameter name collision**: an `Invoke-Command
   -Session` scriptblock had a parameter literally named `$Args`, which
   collides with PowerShell's automatic `$args` variable. `-ArgumentList`
   binding then fails **silently** (no error) - this dropped ALL pass-through
   parameters (`-IsoFolder`, `-RetentionDays`, `-SkipPatchCheckLab`, etc.)
   from the orchestrator to the target script, which silently ran on its own
   hardcoded defaults the whole time. **Fix**: renamed to `$ArgMap`. Verified
   via an isolated `Start-Job` test before/after the rename.
4. **Backslash is not an escape character in PowerShell** - a "re-run this
   command" hint used `\"..\"` inside a nested `$(...)` subexpression, which
   silently failed (non-terminating "term not recognized" error) instead of
   escaping anything. **Fix**: build the flag list as a plain array first,
   then join once - never nest escaped quotes inside `$()` inside a string.
5. **`HKLM\SAM`/`HKLM\SECURITY` registry export denied even as local Admin**
   - by design, these hives require `SeBackupPrivilege` to be explicitly
   *enabled* (Administrators hold the privilege but it's disabled by
   default). Added `Enable-BackupPrivilege` (P/Invoke `AdjustTokenPrivileges`)
   called once before the registry-hive backup loop in `Start-TargetUpgrade.ps1`.
   **Sub-bug caught during testing**: `AdjustTokenPrivileges` returns `TRUE`
   even when it silently fails to enable a privilege the token doesn't hold -
   must also check `GetLastWin32Error() == 1300` (`ERROR_NOT_ALL_ASSIGNED`).
   Verified empirically (non-elevated/UAC-filtered token correctly returns
   `False` after the fix; previously false-positived `True`).
6. **`reg.exe export` never actually consults `SeBackupPrivilege` at all** -
   discovered empirically (exported an HKCU test key successfully with zero
   privilege elevation), meaning enabling the privilege in fix #5 alone would
   NOT have fixed `HKLM\SECURITY` access denial, since `export` only walks a
   key via normal ACL-checked reads. `reg.exe save`, by contrast, calls
   `RegSaveKeyEx` which unconditionally REQUIRES `SeBackupPrivilege` to
   bypass the ACL, and produces a real, standard hive file (same format as
   the live `%windir%\System32\config\*` files) - a more robust
   disaster-recovery format than export's own proprietary container (only
   restorable via `reg import`). **Fix**: switched the registry-hive backup
   loop from `reg.exe export` to `reg.exe save` (kept the `.hiv` extension -
   it's now genuinely accurate). Trade-off accepted: `save` requires
   `SeBackupPrivilege` for ALL FOUR hives now (previously SYSTEM/SOFTWARE
   worked via `export` without needing it) - acceptable since the real
   deployment path (WinRM session as a genuine local Administrator) holds
   and can enable this privilege; only an interactive/UAC-filtered token
   (like the dev sandbox used for testing) would lack it.

7. **Monitoring UI clutter** - the original `Show-ProgressBar` used a manual
   `` `r `` + `Write-Host -NoNewline` ASCII bar to "overwrite" the progress
   line. On the real lab console this did NOT overwrite in place - every
   poll printed a brand-new line, and since `PhaseName`/`Status`/`Source`
   vary in length, each render left fragments of the previous (longer) line
   behind, producing garbled/repeated-line clutter. **Fix**: switched to
   PowerShell's native `Write-Progress` (a self-clearing dedicated UI
   region), removed the now-unneeded `Write-Host ""` spacer calls, and
   embedded `[NN%]` directly into the `-Status` text (the native bar's own
   percentage label can get clipped on narrow terminals, rendering as bare
   fill glyphs with no visible number).
8. **`$WINDOWS.~BT` present + no setup process ≠ "about to reboot"** - the
   Safe OS phase heuristic in `Update-UpgradeStatus.ps1` assumed "image
   staged but no `setup`/`SetupHost`/`SetupPrep` process" meant Server B was
   mid-reboot into WinPE. In one live run this was actually a **dead**
   `setup.exe`: it had been launched via plain `Start-Process` inside
   `Start-TargetUpgrade.ps1`'s `Invoke-Command -Session` (WinRM) remote
   runspace, which inherits a restricted/non-interactive window station -
   Windows Setup can silently fail or hang when launched this way (same
   class of issue as `psexec` without `-i`). Confirmed via a stale (11-day
   old) `setupact.log` and an unrelated Event 1074 pre-dating the launch.
   **Fix**: `setup.exe` is now launched via a locally-registered,
   immediately-triggered Scheduled Task (`OSUpgradeSetupLaunch`) instead,
   decoupled from the WinRM session; the script then polls `Get-Process` to
   confirm the real engine actually started.
9. **Edition-match precheck picked the wrong WIM index** on multi-edition
   media - e.g. matched Index 3 "Datacenter" (Core) when the live server
   actually has Index 4 "Datacenter (Desktop Experience)" (GUI). **Root
   cause**: Core and Desktop-Experience variants of the SAME edition share
   the identical `EditionId` string in the WIM (both `ServerDatacenter`) -
   only `InstallationType` (`Server` = GUI vs `Server Core`) differentiates
   them, and the old filter matched on `EditionId` alone then blindly took
   `$match[0]` (always the lower/Core index). **Fix**: now requires BOTH
   `EditionId` AND `InstallationType` to match; a same-edition-wrong-flavor
   case is now a clear `FAIL` (mismatched media could silently change the
   GUI state) instead of a false `PASS`.
10. **Local GPO backup folder can legitimately be empty** - an empty
    `GPO\GroupPolicy` backup after a run is expected/correct when the target
    has no Local GPO configured (no `gpt.ini`) - `robocopy /MIR` of an empty
    source just produces an empty destination, not a bug. Added a clear
    log line detecting/explaining this case, plus an **optional** `LGPO.exe`
    companion (Microsoft Security Compliance Toolkit) that, if the user
    supplies it next to the target-side scripts, produces a real portable/
    restorable Local GPO backup (`LGPO.exe /b`) and human-readable
    `Registry.pol` dumps (`/parse /m`) alongside the existing
    robocopy/secedit/gpresult steps.
11. **`setup.exe` self-cancelling ~30-40 min in, before ever reaching Safe
    OS/WinPE** - diagnosed via `SetupDiagResults.xml`/`setuperr.log` on
    TestVM1: `CMoSetupOneSettingsHelper...InitializeSettings: Result =
    0x80072EE2` (`ERROR_INTERNET_TIMEOUT`) - Setup's OneSettings
    telemetry/config call timed out because the lab VM has no outbound
    internet access (same `0x80072EE2` already seen in the WUA-search
    precheck WARN). ~37 minutes later: `...OnCancel: Result = 0x800704C7`
    (`ERROR_CANCELLED`) - Setup gave up entirely, ran SetupDiag, and exited
    - all **before any reboot** (`LastBootUpTime` unchanged), so it never
    reached Safe OS. The Safe OS phase heuristic misread "`$WINDOWS.~BT`
    present + no process" as "about to reboot" instead of "already gave
    up". **Fix**: added `/Telemetry Disable` to the `setup.exe` command line
    (confirmed as a real, documented switch via Microsoft Learn's "Windows
    Setup Command-Line Options") so Setup never attempts the
    network-dependent OneSettings call that was timing out.
12. **No automatic cleanup of a stale/abandoned prior attempt** - after a
    failure like #11, `Status` stays `InProgress` forever and re-running
    required a manual reset (unregister tasks, clear registry, rename
    `$WINDOWS.~BT`). **Fix**: added Section 1b to `Start-TargetUpgrade.ps1`
    - checks real activity evidence (live setup process, or `setupact.log`
    written within the last 20 min), not just the `Status` string, and
    either refuses to proceed (genuinely active) or auto-cleans the
    leftover state (not active) before starting fresh. The orchestrator's
    OWN resume-detection had the identical flaw (trusted `Status=InProgress`
    blindly and skipped invoking `Start-TargetUpgrade.ps1` entirely, so
    Section 1b never even got a chance to run) - fixed with the same
    liveness check there too.
13. **`setup.exe` failing with `0xC1900215` (`MOSETUP_E_NO_MATCHING_INSTALL_IMAGE`)**
    - confirmed via a full, fresh `setuperr.log`: `install.wim` has 4
    applicable images (Standard/Datacenter x Core/Desktop Experience) and
    `setup.exe` was never told which one to use. Per Microsoft's own
    `/ImageIndex` docs: "If multiple images are applicable and Windows
    Setup is invoked with `/Quiet`, Windows Setup will fail with error
    MOSETUP_E_NO_MATCHING_INSTALL_IMAGE (0xC1900215)" - exact match to what
    was observed (`ProductKey: SelectImageIndex... No SkuLib Upgrade
    edition available`). **Fix**: the edition-match precheck (bug #9) now
    stores its matched index in `$script:MatchedImageIndex`, and Section 5
    passes it explicitly via `/ImageIndex <N>` on the `setup.exe` command
    line. This is a distinct, deterministic failure independent of the
    OneSettings/network issue (#11) - both can occur separately.
14. **WUA patch-level precheck could hang 10-20+ minutes with zero visible
    progress** - `Microsoft.Update.Session`'s `.Search()` COM call has no
    built-in timeout, and on a server with no internet/WSUS route it
    exhausts its own internal retries before ever throwing, stalling the
    entire pre-check phase silently. **Fix**: wrapped in a `Start-Job`/
    `Wait-Job` with a 60-second hard timeout, falling through to the
    `Get-HotFix`-age fallback quickly instead of stalling indefinitely.
15. **Percentage could visibly regress** (e.g. `20% -> 3%`) when handing off
    from `Start-TargetUpgrade.ps1`'s initial placeholder to
    `Update-UpgradeStatus.ps1`'s live-parsed value from a different internal
    scale. **Fix**: the initial placeholder is now an honest `0%` (removes
    the collision at the source) instead of an arbitrary `20%`, and
    `Set-Phase` (in `Update-UpgradeStatus.ps1`) additionally clamps
    `PercentComplete` to never decrease while `Status=InProgress`. Terminal
    failure and rollback now retain the same stage's highest verified value.
  16. **Added explicit progress evidence fields**: `PercentSource`,
    `ProgressFreshness`, `ProgressUpdatedAtUtc`, `StatusUpdatedAtUtc` and a
    stage high-water value are threaded through registry, JSON, CIM/DCOM,
    WinRM and the live progress display.
17. **`Get-CimInstance -Credential $Credential` threw "A parameter cannot be
    found that matches parameter name 'Credential'"** on every single final
    build-reconfirmation attempt (8x per run, ~2 min of WARN spam) whenever
    the orchestrator was run WITHOUT `-Credential` (the normal case for
    same-domain/already-elevated sessions) - CIM cmdlets, unlike most other
    `-Credential` parameters in PowerShell, do NOT silently accept an
    explicit `$null` value. Every other CIM/WinRM call in this script
    already guarded against this via conditional splatting; this one
    didn't. **Fix**: now splats `-Credential` conditionally, same as
    everywhere else - the bounded-retry fallback (#N/A, added earlier the
    same day) had been masking this by still completing successfully after
    8 failed attempts, so upgrades never actually failed because of it,
    just looked noisy.
18. **Services comparison flagged nearly ALL upgrade-related service churn
    as `RequiresAttention`**, including completely expected changes: a
    real customer test run showed 45 differences (per-user "template"
    services like `CDPUserSvc_33a6c` disappearing because their session
    suffix regenerated, on-demand/Manual services like `TrustedInstaller`/
    `wuauserv` simply not running at snapshot time, new OS-version services
    like Edge Update appearing) and EVERY one of them - including zero
    genuine regressions - tripped `RequiresAttention`, risking customer
    push-back on a successful upgrade. **Fix**: `Invoke-PostUpgradeValidation`
    now classifies each difference as ATTENTION (a service that was
    genuinely always-on - `Running`+`Automatic` - and is no longer
    running/present) vs INFORMATIONAL (per-user session-suffixed services,
    on-demand/Manual services, and well-known Windows self-managing
    services like `TrustedInstaller`/`wuauserv`/`sppsvc` that legitimately
    toggle their own state). Re-running the classification against that
    exact real 45-difference dataset now yields **0 attention items / 45
    informational** -> overall result `Consistent` instead of a scary
    `RequiresAttention`. New registry/JSON fields `ServicesAttentionCount`/
    `ServicesInfoCount`; the orchestrator's final banner now reads e.g.
    "Consistent - no attention items; 45 routine upgrade-related change(s)
    recorded for reference" instead of just the bare word `Consistent`.

19. **Orchestrator showed a misleading "[0% - n/a] Reachable via WinRM (no
    file/DCOM status source yet)"** for 28+ minutes straight in a real test
    run - even though the target had ALREADY finished a fully successful
    upgrade (confirmed via VM console: Windows Server 2022 Datacenter,
    build 20348.169). Two separate root causes, both fixed:
    - **No diagnostic trail**: `Read-RemoteFileWithTimeout` and
      `Get-RemoteStatusViaCimDcom` both silently swallowed every failure
      (`-ErrorAction SilentlyContinue` / bare `catch { return $null }`),
      so there was no way to tell WHY the file-share and CIM/DCOM channels
      never answered even once during that whole run. **Fix**: both now
      accept an optional `-ErrorDetail ([ref]...)` out-parameter capturing
      the real timeout/exception reason; `Get-UpgradeStatus` logs a single
      WARN (throttled to once per occurrence, not once per 15s poll) the
      first time WinRM is confirmed up but neither channel answers,
      naming the actual underlying error from each channel and pointing at
      SMB(445)/DCOM(135+dynamic) firewall rules as the likely cause when
      WinRM(5985/5986) is open but those aren't.
    - **Misleading hard-reset to 0%**: the display line
      `$pct = if ($status.PercentComplete) {...} else {0}` reset to a bare
      `0` on every poll that had no fresh number (e.g. exactly this
      WinRMOnly fallback), which looks exactly like "upgrade restarted /
      lost all progress" even though nothing regressed - a poll simply had
      no live reading that cycle. **Fix**: introduced sticky
      `$lastKnownPercent`/`$lastKnownPercentSource`, updated only when a
      poll has a REAL `PercentComplete`, and always displayed instead of a
      hard `0` - shown with a `"(cached)"` suffix on `PercentSource` when
      the value being displayed isn't from this cycle's live reading, so
      it's honest in both directions (never fakes a live number, never
      fakes a reset to zero).

20. **A real successful TestVM2 run (2019->2022) showed `OSUpgradeProgress.log`
    jumping straight from Downlevel Phase (96%) to Second Boot/OOBE (95%)**,
    with NO Safe OS or First Boot entries at all - and the orchestrator's
    own live log showed the exact same skip. Two DIFFERENT root causes:
    - **Safe OS (Phase 4) - structural, always missing from this log by
      design**: the Event-ID-1074 reboot-watcher scheduled task fires in
      the narrow pre-shutdown window right before the real reboot, so it
      deliberately runs a raw `cmd.exe /c reg.exe add ...` chain (not
      PowerShell) for speed/reliability - meaning it updates the LIVE
      registry correctly but can never call the `Set-Phase` function, which
      is the only place the `OSUpgradeProgress.log` mirror is written.
      **Fix**: the same cmd.exe chain now also appends one more `echo ...
      >> "<BackupFolder>\OSUpgradeProgress.log"` command (still zero
      PowerShell dependency), using the already-known backup folder path
      baked in at task-registration time. Deliberately omits a literal `%`
      character in the echoed text (writes "Percent=40" not "Percent=40%")
      since a lone `%` inside a `cmd.exe /c "..."` command line (as opposed
      to an actual .cmd/.bat file) has inconsistent/parser-dependent
      expansion behavior.
    - **First Boot (Phase 5) - a timing/luck gap, not structural**: this
      phase DOES go through `Set-Phase` properly (so it CAN log), but only
      runs via the 5-minute recurring `OSUpgradePhaseMonitor` task - which
      can't run at all during Safe OS/WinPE (no Task Scheduler service
      there). On a fast upgrade (this run: ~6 minutes total for Safe
      OS+First Boot+OOBE combined), the 5-min cadence can easily never land
      a poll while the machine is specifically in First Boot before the
      OOBE hook (`setupcomplete.cmd`) fires and jumps straight to Phase 6.
      **Fix**: shortened `OSUpgradePhaseMonitor`'s `RepetitionInterval` from
      5 to 2 minutes, meaningfully narrowing (not eliminating - First Boot
      could still theoretically complete in under 2 min) that blind spot.

21. **Confusing dual numbering + fabricated "Estimated" percentages that
    looked like regressions** - a real run's console showed raw
    `Phase=3 (Downlevel Phase) ... Percent=0 (Estimated)` immediately after
    Phase 2 had already reached 15%, right next to the orchestrator's own
    `Stage 3/3: Windows Setup Execution` line - two different, uncorrelated
    numbering schemes (internal Phase 1-7/99 vs customer-facing Stage 1/3-
    3/3) shown side by side with no connecting context, PLUS a genuine
    percentage regression. Two fixes:
    - **Terminology**: rather than renumbering the internal `Phase` field
      (deeply embedded in the registry/JSON schema, resume-detection logic,
      and both scripts - high risk, zero functional value to change now),
      `Set-Phase`'s own `Write-Log` line in BOTH scripts now prefixes every
      single phase-transition log line with `[$stageLabel]` too, e.g.
      `[Stage 3/3: Windows Setup Execution] Phase=3 (Downlevel Phase)...` -
      so the internal Phase number is now always shown WITH its Stage
      context, never standing alone and looking like a competing scheme.
    - **Root cause of the visible regression**: `Start-TargetUpgrade.ps1`'s
      OWN copy of `Set-Phase` (a separate function from
      `Update-UpgradeStatus.ps1`'s, since they run as different processes)
      was MISSING the monotonic-never-decreases-while-InProgress clamp that
      `Update-UpgradeStatus.ps1`'s copy already had - so its hardcoded
      Downlevel-kickoff `-PercentComplete 0` genuinely overwrote Phase 2's
      real 15% with a lower number. **Fix**: added the same clamp for
      parity. Additionally, per customer ask ("remove Estimated, keep only
      Measured"), went further and removed EVERY fabricated "Estimated"
      milestone/fallback percentage for Stage 3 sub-phases with no real
      telemetry or no telemetry YET (Downlevel-no-data-yet, Safe OS,
      First-Boot-no-data-yet, OOBE, and the controlled-reboot 25% guess) -
      those `Set-Phase` calls now simply omit `-PercentComplete` entirely,
      which (combined with `Set-Phase` already skipping the registry write
      whenever it's omitted) leaves the last REAL Measured value untouched
      and still displayed instead of a guessed number that only gets
      superseded moments later. Also removed the Event-1074 reg.exe
      chain's hardcoded `PercentComplete=40 (Estimated)` write for the same
      reason. Net effect: once the first real Measured reading appears
      (usually within seconds of Downlevel starting), the displayed
      percentage should never again show "(Estimated)" for the rest of
      Stage 3 - it either shows a fresh Measured reading, or the orchestrator's
      existing sticky/cached-carry-forward logic keeps showing the last real
      Measured one. Phase 1/2's own small milestone percentages (0/5/15%)
      were deliberately left as-is - those represent OUR OWN script's
      housekeeping progress, not a claim about "the actual OS upgrade",
      which is the customer's stated distinction.

22. **Phase 7 (Completed)'s 100% was still tagged `PercentSource="Estimated"`**
    by default (no `-PercentSource "Measured"` was ever passed on that call)
    - a small leftover inconsistency spotted while confirming the
    Estimated-removal work above: 100% at that point is a VERIFIED fact
    (post-upgrade validation already confirmed `currentBuild -eq
    targetBuild` locally), not a guess. **Fix**: both `Set-Phase -Phase 7`
    calls (`Completed` and `CompletedWithWarnings`) now explicitly pass
    `-PercentSource "Measured"`.

23. **Stage 1/2 (prechecks + backup) had zero GUI-side feedback** - they run
    entirely inside ONE blocking `Invoke-Command` call in the orchestrator's
    Section 3, so the only visible sign of life was Server B's own
    Write-Log/Write-Host lines streaming through live; the blue
    `Write-Progress` bar showed nothing at all for however many minutes that
    took. **Fix**: that same kickoff call is now issued via
    `Invoke-Command -AsJob` instead of synchronously; a loop polls
    `$job.State -eq 'Running'` every second, calling `Receive-Job` (WITHOUT
    `-Keep`, so each call only returns records not already returned - no
    duplicate re-printing) to both (a) keep replaying Server B's live
    Write-Host/Warning/Verbose output exactly as before (Receive-Job replays
    a job's streams through their normal channels) and (b) draw a
    spinner + elapsed-time `Write-Progress` bar ("Stage 1/3-2/3:
    Pre-Upgrade Assessment + Backup running on TargetComputer... \| Elapsed:
    MM:SS...") in between log lines. The genuine `[pscustomobject]@{Success;
    Error}` return value (the only object in the accumulated results with a
    `Success` property - Write-Host output never produces pipeline objects)
    is picked out after the job finishes, preserving the exact same
    `$remoteResult.Success`/`.Error` handling as before.

24. **The "Stage 3/3:" label disappeared from the GUI bar entirely during
    Safe OS/WinPE and other connectivity-gap windows** - noticed from a real
    run's screenshot where the bar showed a bare "Offline / Rebooting..."
    with no Stage prefix at all, even though it's always 100% certain to
    still be Stage 3 at that point (this fallback can only ever fire AFTER
    setup.exe has already launched - Stage 1/2 never reach this code path).
    Root cause: the 3 fallback status objects returned by `Get-UpgradeStatus`
    when WinRM/file/DCOM/ping can't answer (`WinRMOnly`, `PingOnly`/
    Heartbeat, and the full-`Offline` case) never included a `Stage` field
    at all, so `Show-ProgressBar`'s `-Stage` parameter just rendered blank.
    **Fix**: all 3 fallback objects now explicitly set
    `Stage = "Stage 3/3: Windows Setup Execution"`. Also clarified the
    wording of the Heartbeat/Offline `PhaseName` text to explicitly name
    "Safe OS/WinPE" (was the more generic "Transitioning..."/"Rebooting...")
    so a customer watching the bar immediately understands which part of
    the upgrade the silence corresponds to. Purely a label/wording fix - no
    behavior change; Server A still genuinely cannot talk to Server B
    during this window, that's unavoidable.

25. **A real run's GUI bar visibly DROPPED from 88% to 73% while still
    InProgress** - a genuinely fresh, non-null reading that was simply
    LOWER than a previous one (plausible causes: a stale SMB/DCOM read
    racing a concurrent registry write on Server B, or Windows Setup's own
    progress counter briefly dipping between internal sub-tasks within
    Downlevel). Server B's own `Set-Phase` clamp only protects against
    Server B regressing ITS OWN writes - it does nothing to protect Server
    A from an occasional stale/racy READ of an older value through a
    different channel than the one that produced the higher number. A
    visible regression looks exactly like something went wrong to anyone
    watching and directly damages confidence in the tool. **Fix**: Server
    A's own monitoring loop now ALSO clamps the displayed percentage to
    never decrease while `Status="InProgress"` (mirroring Server B's own
    rule, including the same exception - terminal Failed/RolledBack states
    still correctly show their real, lower value uncklamped).

26. **Architectural question raised**: should the console WAIT for /
    explicitly display a distinct "Second Boot completed" step instead of
    jumping straight from Downlevel/Heartbeat to "Success", given the VM
    console can still show "Please wait for the Group Policy Client" (and
    even another brief reconnect) minutes AFTER the orchestrator already
    printed its final summary? **Decision: keep the completion trigger
    exactly as-is, add a clarifying note instead.** "Completed" fires from
    Windows Setup's own documented `/PostOOBE` hook - Microsoft's own
    definition of "the upgrade finished" - plus a local build-number
    re-verification. Waiting for anything further (GP Client refresh, a
    possible extra reboot) has no natural/deterministic stopping point,
    since normal Windows machines do background policy/maintenance work on
    every boot regardless of whether an upgrade just happened - picking a
    later cutoff would make completion detection LESS reliable, not more.
    Instead, both `Completed` and `CompletedWithWarnings` outcomes now print
    an extra `Note:` line explaining that brief post-completion housekeeping
    is normal first-logon behavior, not evidence the upgrade itself is
    incomplete - managing customer perception without compromising the
    deterministic completion signal.

27. **Customer had to ask why Safe OS/First Boot weren't individually shown
    on the console, every time it happened** - the tool never explained
    this itself. **Fix**: the monitoring loop now tracks the last REAL
    numeric `Phase` actually read from a genuine status source (File/CIM-DCOM
    only - the synthetic WinRMOnly/Heartbeat/Offline fallbacks have no Phase
    number). Whenever a new real reading jumps by more than 1 (e.g. 3 ->
    6, meaning Safe OS/4 and First Boot/5 were never individually observed),
    it proactively logs a plain-language `NOTE:` explaining exactly which
    phase(s) were skipped and WHY (Safe OS = zero connectivity in WinPE;
    First Boot = can finish faster than the poll interval) - without the
    customer needing to ask or without you needing to explain it manually
    each time. Only applies to the normal 1-7 sequence; a jump to/from 99
    (RolledBack) is a different, already-explained branch, not a "missed
    phase" gap.

28. **Four polish issues found from a real run's transcript, all fixed
    together**:
    - A 19-SECOND "Offline" blip was followed by a generic "connectivity
      RESTORED" message with no indication of how brief it was - read in
      isolation it looked like a full Safe OS/WinPE reboot cycle had just
      completed, when a real reboot renders every channel unreachable for
      several MINUTES, not seconds. **Fix**: the connectivity-restored
      message is now duration-aware - it reports exactly how long the
      outage lasted and explicitly says a sub-60-second gap is "most
      likely a single transient network blip, NOT a genuine reboot",
      versus a longer gap being "consistent with a genuine Safe OS/WinPE
      reboot transition".
    - The skipped-phase `NOTE:` (bug #27) didn't distinguish "we saw a real
      outage in between, we just couldn't see the individual sub-phases"
      from the more surprising "no outage was observed at ALL, yet phases
      were still skipped" (meaning the whole reboot cycle completed faster
      than even one poll interval could catch full unreachability).
      **Fix**: the tool now tracks whether an outage occurred since the
      last real Phase reading and tailors the NOTE's wording accordingly.
    - The very first "Phase change detected" line always read `'' ->
      'X'`, which looked like a blank/missing value. **Fix**: initialized
      to `"(none - monitoring just started)"` instead of an empty string.
    - **Removed the fabricated Stage 1/2 milestone percentages (0%/5%/15%)
      entirely** - per direct feedback that an arbitrary number for
      prechecks/backup progress doesn't represent anything measurable the
      way Stage 3's real setup.exe telemetry does, and risks looking like
      meaningful data when it's really just a guess. Stage 1/2 now show
      Stage+Phase+Status with no percent number at all (the registry's
      display-fallback still resolves to a plain 0 on a fresh run, so
      nothing breaks downstream). Also aligned Phase 2's Failed-path
      percent from an inconsistent leftover "5" to "0", matching Phase 1's
      own Failed-path convention.

29. **A REAL, deeper bug behind bug #28's duration wording**: the log could
    show `Phase change detected: 'Safe OS/WinPE transition or reboot in
    progress...' -> 'Downlevel Phase'` - which LOOKS like the phase went
    backward (Safe OS -> Downlevel), something Windows Setup's own strictly
    linear model (Downlevel -> Safe OS -> First Boot -> OOBE) can NEVER
    actually do. **Root cause**: the synthetic Heartbeat/Offline fallback
    text asserts a SPECIFIC GUESSED phase ("Safe OS/WinPE...") as if it
    were a confirmed fact, when it's really just "connectivity is down, our
    best guess is Safe OS" - and that guess has been directly proven wrong
    in real runs (a short connectivity gap, then the REAL reading afterward
    showed Server B had never left Downlevel at all - the gap had some
    other cause, e.g. Setup's own internal network-stack work during
    Downlevel prep, or a transient VM/hypervisor blip). The old
    "Phase change detected" logic compared against whatever PhaseName text
    was last shown - including that unconfirmed guess - so "correcting" the
    guess with the real data looked exactly like an impossible backward
    transition. **Fix**: phase-change comparison/logging now tracks
    `$lastConfirmedPhaseName`, updated ONLY from real Phase readings
    (File/CIM-DCOM) - synthetic guess text is never compared against or
    logged as a "transition" at all (the existing Heartbeat/Offline WARN
    already communicates the connectivity-loss context adequately). Three
    outcomes on the next REAL reading: (a) genuinely different phase ->
    normal "Phase change detected" fires as before; (b) SAME phase as
    before the gap AND we just reconnected -> new explicit message: "Server
    B reconnected and confirms it is STILL in 'X' - the connectivity gap
    did NOT correspond to a confirmed phase change"; (c) same phase, no
    recent reconnect -> falls through to the existing stall-warning check
    as before. Also changed the GUI/console DISPLAY during a gap: instead
    of asserting the guessed phase, it now shows the last CONFIRMED phase
    tagged `(connectivity gap - phase UNCONFIRMED; ...)`, mirroring the
    same sticky-percent design pattern already used for `PercentComplete`.

    **Follow-up**: the very FIRST phase ever detected (always Downlevel)
    still logged as `Phase change detected: '' -> 'Downlevel Phase'` -
    there's nothing to "change" FROM at the very start, so an empty-looking
    left side is bound to raise a customer question. Fixed: `$lastConfirmedPhaseName`
    is now `$null` initially, and the very first real reading logs a plain
    `First phase detected: 'Downlevel Phase' (Status=InProgress)` instead
    of the misleading `'' -> 'X'` transition framing.

30. **Feature**: added `-FastPollIntervalSeconds` (default 5) - used ONLY
    while `Mode` is `Heartbeat` or `Offline` (WinRM down), reverting to the
    normal `-PollIntervalSeconds` (default 15) the instant `ActivePolling`
    resumes. A shorter interval specifically during a connectivity gap
    increases the odds of a poll actually landing during a brief window
    where the machine responds again (e.g. a short-lived First Boot state
    before the OOBE hook fires) - directly reduces (does not eliminate -
    First Boot could still be shorter than even 5 seconds on an extremely
    fast VM) the chance of missing an intermediate phase entirely, which
    bug #20/#27 already explain when it does happen.

31. **A new run still showed `[Stage 1/3: Pre-Upgrade Assessment] Phase=1
    ... Percent=0 (Estimated)`** despite bug #28's fix that was supposed to
    remove Stage 1/2's fabricated milestone percentages entirely. **Root
    cause**: omitting `-PercentComplete` correctly stopped WRITING a
    fabricated number to the registry, but the DISPLAY fallback logic
    added alongside it (`Get-UpgradeRegistryValue -Name "PercentComplete"
    -Default 0`) still defaulted to the hardcoded literals `0`/`"Estimated"`
    whenever nothing was stored yet - which on Phase 1's very first call
    ever (fresh registry, nothing to carry forward) reconstructed the exact
    same "Percent=0 (Estimated)" text the whole fix was meant to eliminate.
    **Fix**: the fallback now distinguishes "no real value has EVER been
    stored" (`$null` - print NO percent clause in the log line at all) from
    "a real value exists to carry forward" (print it, unchanged behavior).
    Fixed in BOTH `Set-Phase` copies (`Start-TargetUpgrade.ps1` and
    `Update-UpgradeStatus.ps1`, including its `OSUpgradeProgress.log`
    mirror line). Net effect: Phase 1/2 log lines now read e.g. `Phase=1
    (Pre-Upgrade Assessment) Status=InProgress` with no percent segment at
    all, until Update-UpgradeStatus.ps1's own Downlevel-phase detection
    finds a genuine Measured value and writes it for the first time.

32. **`Phase=3` still looked redundant/confusable right next to `Stage 3/3`**
    in the live console text (e.g. `[Stage 3/3: Windows Setup Execution]
    Phase=3 (Downlevel Phase) Status=InProgress ...`) - two different
    numbering schemes that don't actually correlate 1:1 (Phase 3 through 7,
    and 99, ALL map to the same `Stage 3/3`), so seeing "3" appear twice
    side by side looks like unintentional duplication even with bug #21's
    Stage-prefix fix already in place. **Fix**: dropped the bare `Phase=$Phase`
    number from the LIVE CONSOLE `Write-Log` text in both `Set-Phase`
    copies - now reads `[Stage 3/3: Windows Setup Execution] Downlevel
    Phase - Status=InProgress ...` (friendly name only, no raw number).
    The durable `OSUpgradeProgress.log` mirror file deliberately KEEPS the
    `Phase=N` reference (that's the technical/audit-trail file, a
    different audience than the live console), and the underlying `Phase`
    field itself is untouched in the registry/JSON for ServiceNow/technical
    consumption - this is purely a live-console text simplification.

33. **Live console/log text hardcoded "Server B" in several places**
    (`Start-RemoteUpgradeOrchestrator.ps1` and `Start-TargetUpgrade.ps1`) -
    fine for `PROJECT-NOTES.md`'s own architecture narrative (kept as-is
    there), but looks unprofessional/non-generic in actual runtime output
    shown to a customer. **Fix**: every `Write-Log` line that printed the
    literal string "Server B" now uses the real hostname instead
    (`$TargetComputer` in the orchestrator, `$env:COMPUTERNAME` in
    `Start-TargetUpgrade.ps1`) - e.g. "WinRM connectivity LOST on TestVM2 -
    ... while TestVM2 tears down networking..." instead of a mix of the
    real hostname and the generic "Server B" label in the same sentence.

34. **No prominent, unmistakable message when the target was ALREADY on the
    target OS** - a real run against a server that had already completed
    a prior upgrade only produced one somewhat buried `[SUCCESS]` log line
    ("`TestVM2` already reports a terminal Status=... from a prior run...")
    before falling through to the normal monitoring loop and final
    summary - it never clearly, immediately stated "this server is already
    on Windows Server 2022, nothing was done this run" in a way that's
    impossible to miss. **Fix**: the resume-detection check (Section 2b)
    now ALSO does a LIVE `Get-CimInstance Win32_OperatingSystem` query
    (not just trusting the stored registry value, for maximum
    trustworthiness) and prints a prominent banner the moment a terminal
    `Completed`/`CompletedWithWarnings` prior state is detected:
    ```
    ====================================================================
     TestVM2 IS ALREADY ON THE TARGET OS - NO UPGRADE ACTION TAKEN THIS RUN
    ====================================================================
     Current OS (live check)   : Microsoft Windows Server 2022 Datacenter (build 20348)
     Prior run outcome         : Status=CompletedWithWarnings (Phase=7 'Completed')
     Prior run last updated    : 2026-07-20 01:26:17
    ====================================================================
    ```
    Falls back to the stored `PostUpgradeOSCaption` registry value (with a
    note that the live re-check failed) if the live CIM query itself can't
    be reached for some reason.

## New features (2026-07-23, orphaned profile hygiene check)
- **Orphaned local user profile pre-check** (`Start-TargetUpgrade.ps1`,
  Section 2b, warning-only/non-blocking): enumerates every SID under
  `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList` that
  looks like a real user account (`S-1-5-21-*` - built-in/service SIDs are
  skipped entirely to avoid false positives), and tries to resolve each one
  via `[System.Security.Principal.SecurityIdentifier]::Translate()`. A SID
  that fails to resolve means the owning account (domain or local) no
  longer exists but its local profile registry entry was never cleaned up -
  a classic "orphaned account" hygiene issue. **Zero found -> `PASS`**
  (`No orphaned profile SIDs found under ProfileList.`). **One or more
  found -> `FAIL` (BLOCKING, changed from `WARN` on 2026-07-26 - see below)**
  - logs the count plus each SID and its `ProfileImagePath`, stores
  `OrphanedProfileCount` in the registry, and prints a full REVIEW-FIRST
  cleanup script to the console (inside a `====`-bordered banner) that a
  human can copy/paste and run at their own discretion. That printed script
  deliberately only removes the `ProfileList` registry entries (+ `.bak`
  counterparts) - it does **NOT** delete the actual `C:\Users\<name>`
  folders (real user data) itself; that's called out as a separate,
  explicit, higher-risk manual follow-up step with a "back up first"
  warning, never automated. Nothing here is ever auto-executed by the
  pre-check itself - detection/reporting only; a human must run the
  cleanup (or otherwise resolve the orphaned accounts) and then re-initiate
  the upgrade for this check to PASS.
  **Updated 2026-07-26 (customer request - "wildcard" cleanup)**: the
  printed script is now SELF-DISCOVERING instead of hardcoding the SIDs
  found in that one run - it re-scans `ProfileList` itself and removes
  WHATEVER is orphaned at the moment it's actually run, so the exact same
  copy-pasted script keeps working unchanged if different/additional
  accounts become orphaned later - no need to look up or type any SID by
  hand, one or a hundred, in one shot.
  **Changed 2026-07-26, second follow-up (explicit customer decision)**:
  initially designed as a non-blocking `WARN` (see above) - customer then
  explicitly asked for this to be a hard gate instead: "I do not want the
  script to proceed with the OS upgrade, I want the user to first delete
  orphaned user[s] and come back and initiate OS upgrade again." Changed
  the found-orphans branch from `WARN` to `FAIL`, which automatically
  routes it into the SAME aggregated hard-failure gate every other blocking
  check already uses (see the "confirmed existing behavior" note below) -
  no other logic needed changing. The evaluation-FAILURE path (couldn't
  even determine whether orphaned profiles exist, e.g. a registry read
  error) deliberately stays `WARN`, not `FAIL` - uncertainty about whether
  a problem exists is not the same as a confirmed finding, and shouldn't
  block the upgrade the same way an actual finding does.
  **Expanded 2026-09-09 (customer request)**: the single printed script was
  replaced by THREE explicitly-labelled remediation options in the blocking
  banner, so the admin can pick whichever fits: **Option 1** - per-SID
  `Remove-Item` commands emitted one block per orphaned account found (for
  removing only SOME of them), **Option 2** - the existing self-discovering
  copy/paste block that clears them all at once, and **Option 3** - a
  ready-to-run `Remove-OrphanedProfiles.ps1` that the pre-check now GENERATES
  on the target (written to `$PSScriptRoot`, i.e. the staging folder
  `C:\Temp\OSUpgradeStaging`, path also stored in registry value
  `OrphanCleanupScriptPath`) so there is no copy/paste at all. Consistent
  with the long-standing design, the generated file is written but NEVER
  executed - it also self-discovers at run time, refuses to run
  non-elevated, prints exactly what it will remove and requires the operator
  to type `YES` (unless `-Force`), touches only ProfileList registry entries
  (+ `.bak`), never `C:\Users\<name>` folders, and ends by telling the
  operator to re-run the OS upgrade. The orchestrator's own failure banner
  on Server A gained a matching orphaned-profile branch (alongside the
  existing pending-reboot one) that names the generated script's path and
  the exact re-run command; `$reRunCommand` was hoisted out of the
  pending-reboot branch so all three branches can print it.

**Confirmed existing behavior (2026-07-26, customer question)**: the
pre-check gate ALREADY runs every one of the checks to completion
regardless of individual failures (each check's own `try/catch` only
appends to `$hardFailures`/`$warnings` - none of them individually `throw`
or stop the script) - the single `throw "Pre-upgrade assessment failed:
..."` only fires once, at the very end, joining EVERY failed check's
reason together. So e.g. a pending-reboot failure does NOT stop the run
early - DISM, edition match, licensing, patch level, VMware Tools, RDS CAL,
orphaned profiles etc. all still execute, and the orchestrator's
"Reason(s):" bullet list already reports every failure at once (with extra
specific reboot-remediation guidance layered in ONLY when pending-reboot
happens to be among them) - exactly the "check everything, then tell me
all the open points in one shot" behavior requested. No code change was
needed for this.

## New features (2026-07-26, SFC /scannow + CBS.log check, DISM loosened to WARN)
- **Added a 13th pre-check: "System file integrity (SFC /scannow)"**
  (Section 2.5b, right after DISM ScanHealth) - runs `sfc /scannow` (unlike
  DISM ScanHealth, SFC can actually REPAIR corrupt protected files it finds,
  not just detect them), captures its output to
  `SfcScanNow_<RunStamp>.log`, and ALSO scans `C:\Windows\Logs\CBS\CBS.log`
  (the same underlying log both DISM and SFC write detailed per-file
  results to) for `[SR]` (System Repair/SFC-specific) lines mentioning an
  unrepairable/corrupt file - filtered to only lines timestamped DURING
  this specific scan (`CBS.log` is a large cumulative log spanning the
  whole machine lifetime, so an unscoped scan would pick up irrelevant
  historical noise), giving a supplementary count alongside SFC's own
  (sometimes vague) summary line. Classifies as: no violations -> `PASS`;
  found+auto-repaired, found+NOT fully repairable, couldn't run, or
  unparseable output -> all `WARN` (never blocks - see below for why).
- **DISM ScanHealth's corruption-detected and execution-failure branches
  changed from `FAIL` to `WARN`** - **explicit customer decision**: "for
  both DISM and sfc /scannow, you can display warning if you want any issue
  and proceed by displaying the warning." Previously DISM was a hard gate
  (matching Microsoft's own general guidance that component-store
  corruption is a common root cause of in-place-upgrade failures, and is
  worth blocking on) - now both DISM and SFC are non-blocking, consistent
  with each other, per direct instruction. Worth noting for the record:
  this is a real risk trade-off (unlike the orphaned-profiles check, which
  can never affect `setup.exe` itself, genuine system-file corruption CAN
  cause the actual upgrade to fail partway through) - flagged to the
  customer at the time, but implemented as directed since it was an
  explicit, clear instruction.
- `$totalPrecheckSteps` bumped from 12 to 13 to account for the new check
  (see the in-code maintenance comment above `Add-PreCheckResult` for the
  full current numbered list - keep it in sync going forward).

## New feature (2026-08-26, 14th precheck - block same-version/no-op upgrades)
- **Gap found from the same TestVM2 run**: none of the 13 existing prechecks
  verified the media is actually a NEWER OS version than what's currently
  installed - the "ISO edition matches current OS" check only verifies
  EditionId + InstallationType, which is trivially satisfied when the media
  IS the currently installed version. Result: a same-version repair-install
  ran to completion undetected, wasting ~40 minutes and producing an
  ambiguous SourceBuild==TargetBuild run that later broke phase detection
  (see the bug fix above).
- **Added precheck #14, "Target media build is newer than current OS
  build"** in `Start-TargetUpgrade.ps1`, evaluated right after the media's
  build number is derived (same place `TargetBuild` is set): compares the
  media's build number against the currently installed `CurrentBuildNumber`.
  **Explicit customer decision: hard FAIL** (not WARN) when the media build
  is not newer - this tool is for genuine version upgrades, not
  repair-installs, so an accidental same-version run should be blocked, not
  just flagged. Genuinely inconclusive cases (can't read install.wim/.esd,
  can't parse the version string, edition-match itself failed) stay WARN -
  consistent with the existing DISM/SFC/orphaned-profiles pattern of
  "uncertainty stays WARN, a confirmed finding is FAIL".
- `$totalPrecheckSteps` bumped from 13 to 14; the new check follows the
  exact same conditional structure as "ISO edition matches current OS" (one
  `Add-PreCheckResult` call fires per run, across all its branches).

## Bug found & fixed (2026-08-26, real TestVM2 run - stuck at Safe OS Phase forever)
- **Symptom**: a genuinely-completed upgrade (Hyper-V console confirmed the
  VM was fully up on the new OS, interactively usable) still showed the
  orchestrator stuck at "Safe OS Phase (pending/boot transition)" with a
  frozen `LastUpdated` timestamp, indefinitely. Ruled out network/firewall
  first (customer confirmed `Get-NetConnectionProfile` = DomainAuthenticated,
  `WinRM` service Running) - the LOCAL registry/JSON on the target itself
  were ALSO frozen at the same stale phase, proving this was not a Server A
  reachability problem at all.
- **Root cause**: this specific test upgraded Server 2022 -> Server 2022
  (same build number, `SourceBuild`==`TargetBuild`=="20348", since a
  different-version ISO wasn't available in the lab). `Update-UpgradeStatus.ps1`'s
  Main section decides "still on old OS" vs. "now on new OS" purely via
  `if ($currentBuild -eq $sourceBuild) { ...; return }` BEFORE ever checking
  `if ($currentBuild -eq $targetBuild) { ... }` (where First Boot/OOBE/
  Completed detection lives). Since `$currentBuild` is ALWAYS "20348" here -
  both before and after the real upgrade - the first branch matches forever
  and the script never reaches OOBE/Completed detection. Once Windows
  Setup's own cleanup removed `$WINDOWS.~BT`, execution fell into a final
  `else` that doesn't call `Set-Phase` at all, freezing the registry/JSON
  permanently even though `OSUpgradePhaseMonitor` kept firing every 2 min
  with zero effect.
- **Scope**: only affects a SAME-BUILD upgrade/refresh scenario (a lab-
  testing artifact here) - a genuine cross-version production upgrade
  (2019/2022 -> 2022/2025) would never hit this, since sourceBuild and
  targetBuild always genuinely differ there.
- **Fix**: added a build-number-INDEPENDENT short-circuit right after
  rollback detection and before the build-number branches: if
  `postoobe.marker` exists (an absolute, unambiguous signal that
  `setupcomplete.cmd`'s `/PostOOBE` hook already fired) and `$lastPhase`
  hasn't already reached 7, immediately treat this as OOBE-complete and run
  `Invoke-PostUpgradeValidation` - regardless of what the build-number
  comparison says. Section 1b already guarantees this marker is removed at
  the start of every fresh run, so its mere presence here can only mean
  THIS run's hook genuinely fired. No change to the normal (differing-
  build) case - this is purely an earlier, more-robust safety net.
- **Recovery for the already-stuck TestVM2 run**: re-copy the fixed
  `Update-UpgradeStatus.ps1` into `C:\ProgramData\OSUpgradeAutomation\Scripts\`
  on the target and let the still-registered `OSUpgradePhaseMonitor` task's
  next 2-minute tick pick it up (it will now correctly detect the existing
  `postoobe.marker` and complete validation).

## Bug found & fixed (2026-08-26, real TestVM2 run - stale cross-stage percentage)
- **Symptom**: seconds after Stage 2 (Backup) finished and setup.exe had
  just launched, the orchestrator's progress bar showed "Stage 3/3: Windows
  Setup Execution - [100% - Measured] Downlevel Phase" while the target VM
  console still visibly showed the OLD OS, not a reboot/Setup UI in progress -
  looked like Setup was already done when it had barely started.
- **Root cause**: `Set-Phase` (both scripts) intentionally OMITS writing
  `PercentComplete`/`PercentSource` to the registry when no fresh
  measurement exists yet (2026-07-20 fix, to avoid showing a fabricated
  number). The CONSOLE LOG text already correctly hid a stale value across a
  stage boundary via a `$storedStage -eq $stageLabel` guard - but
  `Write-StatusJson` and the orchestrator's CIM/DCOM registry read
  (`Get-RemoteStatusViaCimDcom`) both pull `PercentComplete`/`PercentSource`
  DIRECTLY from the raw registry, completely bypassing that guard. So the
  instant Stage 3/Downlevel began with no fresh reading yet, the registry
  still literally held Stage 2's ending values (`PercentComplete=100`,
  `PercentSource=Measured`, `PercentStage="Stage 2/3: Backup"`), and both
  the JSON file and the CIM/DCOM channel dumped that stale pair straight
  through, mislabeled under the brand-new `Stage 3/3`/`Downlevel Phase`.
- **Fix**: `Set-Phase` (both scripts) now clears `PercentComplete`/
  `PercentSource` from the registry the moment it detects it's entering a
  genuinely NEW STAGE (not just a new phase - phase transitions WITHIN
  Stage 3, e.g. Downlevel -> Safe OS, still intentionally carry the last
  real value forward) with no fresh percent supplied. This makes the
  console log, JSON file, and CIM/DCOM channel all agree "no measurement
  yet for this stage" instead of one channel silently disagreeing. No
  change to the intentional within-stage carry-forward behavior (Safe OS
  still shows the last real Downlevel reading, etc).

## New features (2026-08-26, System State backup added to Stage 2)
- **Added System State backup as backup task 8 of 8** (`$totalBackupSteps`
  bumped 7 -> 8) in `Start-TargetUpgrade.ps1`, right after the RDS CAL
  license DB backup step. First checks `Get-WindowsFeature -Name
  Windows-Server-Backup`; if not installed, runs `Install-WindowsFeature
  -Name Windows-Server-Backup` before proceeding (per explicit customer
  ask), then runs `wbadmin.exe start systemstatebackup -backupTarget:
  <drive> -quiet` (output redirected to `SystemStateBackup_<RunStamp>.log`).
- **Cannot literally live inside `$backupFolder`** - confirmed via
  Microsoft Learn ("wbadmin start systemstatebackup"): `-backupTarget` only
  accepts a drive letter/GUID-based volume or a UNC network share, never an
  arbitrary local subfolder path. Targeted at `$driveRoot` instead (the
  SAME drive that hosts every other backup this run, e.g. `D:`) as the
  closest possible match to "alongside the other backups" - wbadmin
  auto-creates `<drive>:\WindowsImageBackup\<ComputerName>\` there. A
  `SystemStateBackup_Location.txt` pointer file is left inside
  `$backupFolder` so anyone browsing the per-run folder can still find
  where the real data landed; the same path is also stored in the registry
  (`SystemStateBackupPath`).
- Non-blocking (`WARN`, not `FAIL`) on any failure - feature-install
  failure, wbadmin non-zero exit code, or any other exception - consistent
  with every other Section 3 backup task (a failed backup step logs and
  moves on, it does not abort the whole backup phase or the upgrade).

## New features (2026-08-26, RDS CAL license server version-compatibility check)
- **Enhanced the existing "RDS Session Host CAL license server check"**
  (still check #12 of 13, still WARN-only, no gate/percentage-count change)
  per a customer ask, confirmed against Microsoft's own documented RDS CAL
  version-compatibility rules (learn.microsoft.com/windows-server/remote/
  remote-desktop-services/rds-client-access-license): CALs are **not**
  backward compatible - a license server can only install/issue CALs for
  its OWN Windows Server version or an EARLIER one, never a later one. So
  once this session host is upgraded, its configured CAL license server(s)
  must (a) run an OS version >= the TARGET OS being upgraded to, and (b)
  already have CALs for that target OS version installed - otherwise
  clients lose the ability to obtain a valid RDS CAL once the post-upgrade
  licensing grace period ends.
- For every configured license server (`HKLM:\SYSTEM\CurrentControlSet\
  Control\Terminal Server\RCM\Licensing Core\LicenseServers`), the check now
  makes a best-effort remote `Get-CimInstance Win32_OperatingSystem` call
  (bounded by a 15s `Start-Job`/`Wait-Job` timeout, same defensive pattern
  as the WUA patch-level search - an unreachable/firewalled license server
  can never stall the pre-check phase) and compares its `BuildNumber`
  against this run's `TargetBuild` (already derived earlier by the ISO
  edition-match check). Each server is classified `INCOMPATIBLE` (older
  build than the target), `OK` (same/newer - still reminds the admin to
  confirm CALs for the target OS are actually installed there), or
  "could not verify" (unreachable/timeout/no target build known yet) -
  all folded into one combined `Detail` string on the single WARN result
  (still exactly one `Add-PreCheckResult` call per run, same as before).
  Deliberately stayed **WARN, not FAIL** - this remains a licensing/
  compliance concern (same category as OS activation), and the remote
  query itself may not always be possible depending on network/WMI
  reachability to a third machine, so a failed lookup must not block the
  upgrade.

## New features (2026-07-28, DISM/SFC reverted from WARN back to hard-blocking FAIL)
- **Reverted the 2026-07-26 WARN-only experiment** - **explicit customer
  decision**, agreeing with the risk trade-off flagged at the time: both
  DISM ScanHealth's confirmed-corruption branch AND SFC /scannow's two
  confirmed-corruption branches (found+auto-repaired, found+NOT fully
  repairable) are now `FAIL` again (hard-blocking), same as before
  2026-07-26. Only genuinely INCONCLUSIVE outcomes stay `WARN` - DISM/SFC
  failing to run at all, unparseable output, or SFC reporting it couldn't
  perform the operation (e.g. another servicing op in progress/Safe Mode
  required) - since uncertainty about whether a problem exists is not the
  same as a confirmed finding (same reasoning already used for the
  orphaned-profiles evaluation-failure path).
- **No change needed to the "run every check, then report all failures
  together" gate behavior** - this was already how `Add-PreCheckResult`/
  `$hardFailures`/the single aggregated `throw` in Section 2c worked (see
  the 2026-07-26 "Confirmed existing behavior" note above): every one of
  the 13 checks still runs to completion regardless of individual
  pass/warn/fail outcomes, and the orchestrator's existing "Reason(s):"
  banner + "ACTION REQUIRED: Resolve the reason(s) listed above... then
  re-run this same command" messaging already tells the admin to close out
  every listed failure item before re-initiating the upgrade - this now
  applies to DISM/SFC corruption findings again, same as any other hard
  failure (orphaned profiles, pending reboot, edition mismatch, etc.).


## New features (2026-07-24, task-count-based Stage 1/2 percentages)
- **Stage 1 (Pre-Upgrade Assessment) and Stage 2 (Backup) now report a real,
  climbing percentage** instead of no percent at all (which is what bug
  #28/#31 deliberately left them at, since fabricated milestone numbers
  weren't meaningful) - customer proposed a genuinely measurable
  alternative: count of discrete checks/tasks completed. `Add-PreCheckResult`
  (Stage 1, 12 named checks - DC/cluster/diskspace/reboot/DISM/setup.exe-
  located/edition/licensing/patch/VMware-Tools/RDS-CAL/orphaned-profiles)
  and the new `Update-BackupProgress` helper (Stage 2, 7 named tasks -
  services snapshot/registry hives/GPO robocopy/LGPO.exe/secedit/gpresult/
  RDS CAL DB) each increment a running counter and call `Set-Phase` with
  `-PercentComplete [math]::Min(100, 100 * done/total) -PercentSource
  "Measured"` after every single check/task, regardless of PASS/WARN/FAIL
  (a check that failed was still WORKED THROUGH - it's an accurate unit of
  completed effort either way). `Notes` on each call reads e.g. "Task 3/7
  complete: Registry hives backup" for extra clarity in the console/log.
  **Maintenance note**: `$totalPrecheckSteps` (12) and `$totalBackupSteps`
  (7) are explicit constants with a comment listing exactly which checks/
  tasks they count - bump both the number AND the comment if a check/task
  is ever added or removed, since there's no dynamic way to auto-detect
  this from the procedural code structure.
- **Fixed a real design conflict this surfaced**: the existing monotonic
  "never decreases while InProgress" clamp (bug #25) was GLOBAL across the
  whole run, sharing one `PercentComplete` registry value for every phase -
  fine when only Stage 3 had a real percentage, but as soon as Stage 1/2
  ALSO got real (independently-scaled) percentages, the clamp would have
  wrongly forced Stage 2's fresh start (e.g. 14% on its first completed
  task) up to Stage 1's ending 100%, and later forced Stage 3 Downlevel's
  own genuinely-lower first real reading (e.g. 15%) up to Stage 2's ending
  100% too - completely defeating each stage's independent 0-100 scale.
  **Fix**: added a `PercentStage` registry value (internal bookkeeping,
  not exposed in the JSON) recording which Stage's percentage is currently
  stored; the clamp - and the carry-forward DISPLAY fallback used during
  Safe OS/OOBE/no-data-yet gaps - now both only apply when the stored value
  belongs to the SAME stage as the current call. Within Stage 3 itself
  (Phases 3-7/99 all share one stageLabel) this is a complete no-op - the
  existing cross-phase carry-forward behavior there is unchanged; it only
  ever kicks in to correctly block carry-forward ACROSS a stage boundary.
- **GUI progress bar during Stage 1/2 now shows a REAL, filling percentage**
  (not just the spinner/elapsed-time indeterminate bar) - the orchestrator's
  Stage 1/2 blocking-call loop (Section 3) now also polls Server B's
  `upgrade_status.json` every ~3 seconds via the existing
  `Read-RemoteFileWithTimeout` helper (a plain SMB file read - NOT the
  heavier multi-channel `Get-UpgradeStatus`, since `$session` is already
  busy running the kickoff job for the whole duration of this loop and
  can't service a second concurrent command), extracting
  `PercentComplete`/`PhaseName`. Sticky between polls (keeps showing the
  last good value on a transient/partial-write read failure) and shows no
  percentage at all (indeterminate bar) until the very first successful
  read - same "never fake a number" principle used everywhere else. Status
  text now reads e.g. `| [42%] Elapsed: 01:23 (Registry hives backup) - ...`.
  **Regression caught before it shipped**: `Read-RemoteFileWithTimeout` was
  originally defined in "Section 4 - Monitoring Loop Functions", AFTER
  Section 3 in the script's linear execution order - PowerShell does not
  hoist function definitions, so calling it from Section 3 would have
  failed at runtime with "term not recognized" the first time this code
  path actually ran. Fixed by relocating just that one function's
  definition to before Section 3.

## New features (2026-07-20, progress-accuracy + stage grouping)
- **Adopted Microsoft's documented `HKLM:\SYSTEM\Setup\mosetup\Volatile\SetupProgress`
  registry value** (REG_BINARY, 0-100, confirmed via Microsoft Learn's
  "Windows 10 upgrade issues troubleshooting" article) as the new
  top-priority source in `Get-SetupProgressPercent` (`Update-UpgradeStatus.ps1`).
  Unlike the previously-top-priority undocumented `ChildCompletion\setup.exe`
  DWORD, this key is officially documented AND spans all four Windows-Setup
  phases (Downlevel/Safe OS/First Boot/Second Boot-OOBE) as one continuous
  0-100 arc, so it no longer needs the old per-phase clamps
  (`[math]::Min(...,55)` / `[math]::Max(...,60)`) when it's the source -
  the old per-phase clamps. ChildCompletion and Panther regex percentages
  have now been removed; if MoSetup is absent, the prior verified sample is
  carried forward without changing its progress timestamp.
- **Stage 1/2/3 grouping**: both `Set-Phase` functions (`Start-TargetUpgrade.ps1`
  and `Update-UpgradeStatus.ps1`) now also compute and persist a `Stage`
  registry/JSON value - "Stage 1/3: Pre-Upgrade Assessment" (Phase 1),
  "Stage 2/3: Backup" (Phase 2), "Stage 3/3: Windows Setup Execution"
  (Phases 3-7, i.e. Downlevel -> Safe OS -> First Boot -> OOBE -> Completed),
  with a "(Rolled Back)" suffix for Phase 99. The orchestrator's
  `Get-RemoteStatusViaCimDcom` reads this field too, and `Show-ProgressBar`
  now prefixes its `Write-Progress` status text with it (e.g. "Stage 3/3:
  Windows Setup Execution - [42% - Measured] Downlevel Phase ..."), and the
  CLI "Phase change detected" log line is prefixed with `[Stage]` too - so
  it's immediately obvious at a glance which of the 3 broad stages is
  running, on top of the existing granular phase/percent detail.

## New features (2026-07-18, customer usability asks)
- **Upgrade-path banner**: as soon as the ISO/edition match precheck (bug
  #9) confirms a match, `Start-TargetUpgrade.ps1` now flashes a prominent
  "UPGRADE PATH CONFIRMED" banner showing `Current OS : <caption> (build
  NNNNN)` / `Target OS : <friendly image name> (build NNNNN)` - the
  earliest honest point this info is fully known, rather than only quietly
  logging it later during baseline recording. `TargetOSCaption` also
  stored in the registry/JSON so the orchestrator can surface it too.
- **Licensing precheck is now non-blocking**: an unactivated OS is a
  licensing/compliance concern, not a technical reason to refuse to
  upgrade a server that would otherwise upgrade fine - changed from a hard
  `FAIL` to a `WARN`, recording `PreUpgradeLicenseStatus` for later
  reference. `Invoke-PostUpgradeValidation` now ALWAYS produces an explicit
  `LicenseRecommendation` string, refined into 4 distinct cases rather than
  a generic "licensed = fine" (this script never activates the OS itself,
  and in-place upgrades commonly reset/require activation regardless of
  prior state, so "was licensed, still licensed" alone isn't very
  meaningful - what matters is whether the UPGRADE ITSELF plausibly caused
  a regression):
  - Licensed before AND after -> "No action needed."
  - NOT licensed before, Licensed after -> "commonly auto-activated via
    KMS/AD-Based Activation after reboot. No action needed."
  - Licensed before, NOT licensed after -> flagged as a POSSIBLE
    upgrade-caused regression - "RECOMMENDATION: investigate and
    re-activate... before closing this change."
  - NOT licensed before OR after -> explicitly labeled a PRE-EXISTING
    condition the upgrade did NOT cause - "RECOMMENDATION: activate...
    as a standard part of closing this change" (not alarming, just a
    routine follow-up).
  Surfaced as its own permanent line in the orchestrator's final summary
  (`Licensing/Activation : ...`), not folded silently into Notes.

All fixes verified via `[System.Management.Automation.Language.Parser]::ParseFile()`
syntax checks plus isolated `Start-Job`/standalone-script empirical tests
before being applied to the real files.

## Prior related work (reference only, not part of this solution)
`OSUpgradeAutomation/` (sibling folder, no "1" suffix) - an earlier
BigFix-oriented design using the same registry-tracking pattern this solution
was based on/extended from. Has its own `README.md`,
`Get-OSUpgradePhaseStatus.ps1`, `Remove-OSUpgradeArtifacts.ps1`, hooks. Useful
for cross-referencing phase-detection heuristics, but not actively maintained
alongside this solution.

## Full phase list
| # | Name | Meaning | Percent behavior |
|---|------|---------|-----------|
| 1 | Pre-Upgrade Assessment | DC/cluster/diskspace/reboot/DISM/edition/licensing/patch-level/VMware Tools/RDS CAL/orphaned-profiles checks on Server B | Task-count based: (checks completed / 12) x 100, climbs with every check regardless of PASS/WARN/FAIL |
| 2 | State & Policy Backup | Registry hives, Local GPO (+ optional LGPO.exe) + secedit export, gpresult, RDS CAL DB (if applicable) saved to `D:\UpgradeBackup` | Task-count based: (tasks completed / 7) x 100 |
| 3 | Downlevel Phase | Still on the source build; `setup.exe` actively running (launched via `OSUpgradeSetupLaunch` Scheduled Task) | Measured only from `mosetup\Volatile\SetupProgress`; otherwise carries the last verified value and timestamp |
| 4 | Safe OS Phase | WinPE - the genuine blind window; no script/task can run here at all (Event 1074 marks the phase transition instantly, but writes no percent) | No telemetry possible - the last real Downlevel measurement (often already 80-90%+) persists unchanged through this phase |
| 5 | First Boot Phase | New build has booted; `SystemSetupInProgress=1` while roles/settings migrate | Same MoSetup-only live measurement as Downlevel; otherwise carries forward the last verified value |
| 6 | Second Boot (OOBE) Phase | `setupcomplete.cmd` fired `/PostOOBE`; finalizing configuration/cleanup | One-shot hook, no ongoing counter - carries forward the last real First Boot measurement unchanged |
| 7 | Completed | Post-upgrade validation ran (build/edition/activation/critical-services checks); `Completed` or `CompletedWithWarnings` | 100 (Measured - a verified fact, build match already confirmed locally) |
| 99 | Rolled Back / Failed | `setuprollback.cmd` fired `/PostRollback` - upgrade failed and Windows reverted to the source OS; SetupDiag results copied if present | Retains the highest verified Stage 3 percentage and marks it `Terminal` |

## Open items / not yet done
- No automated end-to-end test of a full upgrade run to completion yet
  (testing so far has hit real issues at the Downlevel/Safe OS boundary on
  `TestVM1`, now fixed - a full completed run is still pending).
- Post-upgrade validation's `$criticalServices` list in
  `Update-UpgradeStatus.ps1` is a generic placeholder (`RpcSs`, `EventLog`,
  `Winmgmt`) - tune per actual server role before production use.
