# Windows Server OS Upgrade Automation

This project remotely assesses, backs up, starts, monitors, and validates an
in-place Windows Server upgrade.

- **Server A** is the management server. It stages the package, starts the
  target workflow, reads status, and reports the result.
- **Server B** is the target server. It runs assessment and backup, launches
  Windows Setup, owns all phase/progress state, survives the reboots, and
  performs post-upgrade validation.

Normal flow:

```text
Assess -> Back up -> Launch Setup -> Reboot phases -> Validate live build
```

## Which File Do I Run?

For a normal assessment, upgrade, or monitoring session, run only the Server A
orchestrator. It stages the required Server B files automatically.

| File | Runs on | Purpose | Operator action |
| --- | --- | --- | --- |
| `ServerA-Orchestrator\Start-RemoteUpgradeOrchestrator.ps1` | Server A | Main entry point for assessment, kickoff, and monitoring | Run this file |
| `ServerB-Target\Start-TargetUpgrade.ps1` | Server B | Assessment, backup, task registration, and Setup kickoff | Staged and invoked automatically |
| `ServerB-Target\Update-UpgradeStatus.ps1` | Server B | Phase, progress, failure detection, and final validation | Runs as a scheduled task and Setup hook |
| `ServerB-Target\OSUpgradeShared.ps1` | Server B | Shared registry and JSON status writer | Required; staged automatically |
| `ServerB-Target\setupcomplete.cmd` | Server B | Windows Setup post-OOBE hook | Required exact filename |
| `ServerB-Target\setuprollback.cmd` | Server B | Windows Setup rollback hook | Required exact filename |
| `ServerB-Target\Remove-UpgradeArtifacts.ps1` | Server B | Safe post-run cleanup | Run manually only after reviewing evidence |
| `Tests\Run-SafeTests.ps1` | Development/admin host | Non-operational syntax and regression checks | Run before lab or production use |

## Before You Run

From Server A, confirm:

- The latest complete package is present on Server A, including `Tests`,
  `ServerA-Orchestrator`, and `ServerB-Target`; a fresh kickoff stages the
  target scripts automatically. Do not run the target starter manually.
- The repository layout above is intact. The orchestrator requires all six
  target-side files and refuses to start if one is missing.
- The account used by Server A is a local administrator on Server B. The
  orchestrator verifies this again before staging.
- Server B is reachable through WinRM HTTP/5985 or HTTPS/5986.
- Server B has exactly one suitable ISO under `D:\ISO`, at least 32 GB free
  on the system drive, and `D:\UpgradeBackup` available.
- A maintenance window, recovery plan, and recoverable lab validation exist
  for the real source OS, target media, edition, and credentials.

Verify the **UPGRADE PATH CONFIRMED** banner before kickoff: the ISO determines
the destination, not the target computer name. For example, Server 2022 is
build `20348`; Server 2025 is build `26100`. A prior WS2019 lab run selected
Server 2025 media, so check the actual ISO if the goal is Server 2022.

Other defaults are `D:\upgrade_status.json` for live status,
`C:\Temp\OSUpgradeStaging` for staging, and
`C:\ProgramData\OSUpgradeAutomation` for target runtime files.

Do not use `-SkipPatchCheckLab`, `-SkipDismScanHealthLab`,
`-SkipSfcScanNowLab`, or `-SkipSystemStateBackup` for production acceptance or
a production upgrade. Those switches intentionally leave required evidence
unverified or missing.

## Commands: test, lab upgrade, monitor, production

Use an **elevated PowerShell window on Server A**. The first command runs from
the package root; subsequent commands run from `ServerA-Orchestrator`. In the
examples, that package root is `C:\OSUpgradeAutomation` on Server A. Adjust
only this local path if your package is elsewhere. Paths such as `D:\ISO`
refer to **Server B**, not Server A. On each continued line, the backtick
must be the final character (no trailing spaces after it).

### 1. Run safe package tests

These tests do not start an upgrade, modify the target registry, create
scheduled tasks, or delete files. Stop if they fail.

```powershell
Set-Location 'C:\OSUpgradeAutomation'
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File '.\Tests\Run-SafeTests.ps1'
$LASTEXITCODE
```

To run the following direct `.\Start-RemoteUpgradeOrchestrator.ps1` commands,
allow script execution **only in this PowerShell session**:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Set-Location 'C:\OSUpgradeAutomation\ServerA-Orchestrator'
```

If a higher-priority policy still prevents direct execution, invoke the same
script according to your organization's approved policy; a process-scoped
bypass cannot override a policy enforced at a higher scope. If direct
execution is merely blocked by the current session's policy, the alternative
is `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File
'.\Start-RemoteUpgradeOrchestrator.ps1'` followed by the same arguments.
Both forms expose the script exit code through `$LASTEXITCODE`.

### 2. Test on a disposable lab VM

Restore a known-clean checkpoint and verify that WS2019 is running the source
OS and that `D:\ISO` contains **only the intended ISO**. These switches leave
patch currency, DISM, SFC, and system-state backup unverified; this is **not**
production acceptance. For an assessment first (writes reports and may mount
the ISO, but does not launch Setup):

```powershell
.\Start-RemoteUpgradeOrchestrator.ps1 `
    -TargetComputer 'WS2019' `
    -IsoFolder 'D:\ISO' `
    -BackupRoot 'D:\UpgradeBackup' `
    -StatusJsonPath 'D:\upgrade_status.json' `
    -SkipPatchCheckLab `
    -SkipDismScanHealthLab `
    -SkipSfcScanNowLab `
    -PrecheckOnly
$LASTEXITCODE
```

Require `Status=AssessmentPassed` and check the logged target OS/build.
`-SkipPatchCheckLab` only bypasses the patch-age gate for a disposable lab
machine; it does not speed up Setup. If the assessment passed and the media is
correct, **start the upgrade once**:

```powershell
.\Start-RemoteUpgradeOrchestrator.ps1 `
    -TargetComputer 'WS2019' `
    -IsoFolder 'D:\ISO' `
    -BackupRoot 'D:\UpgradeBackup' `
    -StatusJsonPath 'D:\upgrade_status.json' `
    -SkipPatchCheckLab `
    -SkipDismScanHealthLab `
    -SkipSfcScanNowLab `
    -SkipSystemStateBackup `
    -DisableAutoCleanup `
    -PollIntervalSeconds 5 `
    -FastPollIntervalSeconds 2 `
    -TimeoutMinutes 240
$LASTEXITCODE
```

**This command launches Windows Setup and reboots WS2019.** It also monitors
the run in the same window. `-DisableAutoCleanup` preserves tracking artifacts
for inspection; faster polling improves visibility, not Setup speed. Exit `0` indicates confirmed success; check the reported status and the live
build below before claiming upgrade success. Exit `2` means monitoring ended
without confirmation; see [Interpret the Result](#interpret-the-result).

### 3. Monitor or resume an existing attempt

Leave the kickoff window open. If Server A closes or the monitor returns exit
code `2`, open another elevated PowerShell window on Server A and run **only**
this command; it does not start another upgrade:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Set-Location 'C:\OSUpgradeAutomation\ServerA-Orchestrator'
.\Start-RemoteUpgradeOrchestrator.ps1 `
    -TargetComputer 'WS2019' `
    -StatusJsonPath 'D:\upgrade_status.json' `
    -MonitorOnly `
    -PollIntervalSeconds 5 `
    -FastPollIntervalSeconds 2 `
    -TimeoutMinutes 240
$LASTEXITCODE
```

`-MonitorOnly` does not stage files or run assessment, backup, or Setup. It
may request an existing phase-monitor task to refresh stale status. **Never
repeat the full-upgrade command just because monitoring timed out.**

On **Server B**, while reachable, inspect the live status and the monitor
task from a separate elevated PowerShell window:

```powershell
Get-Content -LiteralPath 'D:\upgrade_status.json' -Raw |
    ConvertFrom-Json |
    Select-Object Phase, PhaseName, Status, PercentComplete,
        TargetBuild, PostUpgradeBuild, LastUpdated, Notes |
    Format-List
Get-ScheduledTask -TaskName 'OSUpgradePhaseMonitor' |
    Select-Object TaskName, State
Get-ScheduledTaskInfo -TaskName 'OSUpgradePhaseMonitor' |
    Select-Object LastRunTime, LastTaskResult, NextRunTime
Get-Content -LiteralPath 'C:\ProgramData\OSUpgradeAutomation\Logs\Update-UpgradeStatus.log' -Tail 40
```

The task may be absent after confirmed terminal completion. During Safe OS
the target cannot run PowerShell; an offline period, frozen percentage, or
`STALE` snapshot alone does not prove failure or success. For the timeline
and other files, see [Evidence and Logs](#evidence-and-logs).

### 4. Production assessment and upgrade

Only after the maintenance window, recovery plan, correct media/edition and
credentials have been verified, use **no lab skip switches** and do not
disable automatic cleanup. Replace `ServerB.contoso.com` with the actual
production target; run from `C:\OSUpgradeAutomation\ServerA-Orchestrator`
on Server A. Assess first:

```powershell
.\Start-RemoteUpgradeOrchestrator.ps1 `
    -TargetComputer 'ServerB.contoso.com' `
    -IsoFolder 'D:\ISO' `
    -BackupRoot 'D:\UpgradeBackup' `
    -StatusJsonPath 'D:\upgrade_status.json' `
    -PrecheckOnly
$LASTEXITCODE
```

Exit `0` with `AssessmentPassed` means only assessment passed, **not** that
Windows was upgraded. Check the expected target OS/build and address all
blocking findings. Then, during the approved window, run this **once**:

```powershell
.\Start-RemoteUpgradeOrchestrator.ps1 `
    -TargetComputer 'ServerB.contoso.com' `
    -IsoFolder 'D:\ISO' `
    -BackupRoot 'D:\UpgradeBackup' `
    -StatusJsonPath 'D:\upgrade_status.json' `
    -TimeoutMinutes 240
$LASTEXITCODE
```

This performs the required checks and system-state backup before launching
Setup, then monitors through reboots. For production monitoring after a
disconnect, reuse the `-MonitorOnly` command above with the production
hostname instead of `WS2019`. For alternate credentials, pass
`-Credential (Get-Credential)` to the assessment, kickoff **and** monitor
commands. Add `-UseSSL` to each to require validated WinRM HTTPS/5986;
`-SkipCertificateCheck` weakens identity validation and is not for production.
For all parameters:

```powershell
Get-Help '.\Start-RemoteUpgradeOrchestrator.ps1' -Full
```

## What You Will See

The console groups the workflow into three stages while Server B records the
more detailed phase:

| Phase | Meaning | Progress behavior |
| --- | --- | --- |
| 1 | Pre-upgrade assessment | Task-count milestone |
| 2 | State and policy backup | Task-count milestone |
| 3 | Downlevel; Setup runs on the source OS | Microsoft MoSetup live percentage only |
| 4 | Safe OS / reboot transition | Last verified percentage is carried forward |
| 5 | First Boot on the new build | MoSetup percentage when available |
| 6 | Second Boot / OOBE | Last verified percentage is carried forward |
| 7 | Post-upgrade validation / completion | Verified completion reaches 100% |
| 99 | Failure or rollback | Retains the highest verified Stage 3 percentage |

Event ID 1074 marks an expected reboot disconnect but never invents a
percentage. Safe OS is a genuine blind window where Server B cannot run the
status task. If Setup disappears on the source build without Event 1074 or a
Panther terminal error, the target waits at least ten minutes before reporting
a diagnostic terminal failure.

### Progress visibility and stale-status recovery

The orchestrator enables native PowerShell progress and also prints periodic
`[PROGRESS]` (assessment/backup) and `[TRACK]` (Setup) lines, so tracking remains
visible in hosts that cannot draw a native bar. Before the first measured
Setup percentage, the bar is indeterminate and says `Awaiting measured progress`;
it does not manufacture a cached `0%` or carry backup's `100%` into Setup.

Before launching Setup, Server B verifies that the phase-monitor task can run
as SYSTEM, load its shared helpers, and write the tracking registry. Failure
stops kickoff. The normal monitor is started after the starter lock is released,
runs every two minutes, and also runs at startup. Event 1074 goes through the
guarded status writer; later restarts cannot reset First Boot or completion to
Safe OS. Safe OS remains inferred, and a short phase may finish between polls.

Server A prefers authenticated WinRM registry reads while WinRM is available,
then falls back to SMB JSON and CIM/DCOM. If an InProgress snapshot has not
changed for 150 seconds, the console labels it `STALE` rather than presenting
it as the current phase. At initial connection, reconnection, and while stale,
Server A requests an existing monitor run (at most once per minute) and records
the live build, task state and `LastTaskResult`. It does not restart a running
validation task, launch Setup, or infer success from reachability/a lock screen.
Monitor exceptions and lock deferrals are recorded in `Update-UpgradeStatus.log`.

For an already-stalled attempt using older deployed scripts, preserve its logs,
JSON and registry state. `-MonitorOnly` does not stage updated target files:
copy the updated `ServerB-Target\Update-UpgradeStatus.ps1` and
`ServerB-Target\OSUpgradeShared.ps1` into the existing
`C:\ProgramData\OSUpgradeAutomation\Scripts` folder on Server B, without
running the starter or cleanup. Then, in elevated PowerShell on Server B:

```powershell
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File 'C:\ProgramData\OSUpgradeAutomation\Scripts\Update-UpgradeStatus.ps1'

Get-CimInstance -ClassName Win32_OperatingSystem |
    Select-Object Caption, BuildNumber, LastBootUpTime
```

Resume observation on Server A with the `-MonitorOnly` command above. This
reconciles current build, Setup state and existing hook markers; it never starts
another upgrade. The normal updated task registration applies to future kickoffs.
An unexpected finished build fails validation: Server 2022 is build `20348`,
whereas Server 2025 media selects build `26100`. Check the logged upgrade path
and `TargetBuild`; a machine named `WS2019` need not still be running Server 2019.

## Interpret the Result

| Exit code | Meaning | Safe action |
| --- | --- | --- |
| `0` | Assessment passed, or the upgrade completed and the live build matched | Check the final status to distinguish `AssessmentPassed`, `Completed`, and `CompletedWithWarnings` |
| `1` | Assessment, backup, kickoff, validation, or rollback failure | Review the target status and evidence table below |
| `2` | Monitoring ended without independently confirmed success | Resume with `-MonitorOnly`; do not assume success or failure |

Full upgrade success requires exit `0`, Phase `7`, status `Completed` or
`CompletedWithWarnings`, matching `PostUpgradeBuild`/`TargetBuild`, and an
independent matching live-build read by Server A after WinRM returns.

On Server B, verify the live result:

```powershell
$status = Get-Content -LiteralPath 'D:\upgrade_status.json' -Raw |
    ConvertFrom-Json
$status | Select-Object Phase, Status, TargetBuild, PostUpgradeBuild,
    PostUpgradeValidationResult, ServicesComparisonResult, Notes

Get-CimInstance -ClassName Win32_OperatingSystem |
    Select-Object Caption, BuildNumber, LastBootUpTime

Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\OSUpgradeAutomation' |
    Select-Object Phase, Status, TargetBuild, PostUpgradeBuild,
        PostUpgradeValidationResult, ServicesComparisonResult
```

`CompletedWithWarnings` means the target build was verified, but activation or
the post-upgrade services comparison needs review. It is not the same as an
unqualified healthy result.

## Evidence and Logs

Check these locations before cleanup. ProgramData tracking data is temporary;
the run folder under `D:\UpgradeBackup` is intentionally durable.

| Evidence | Machine | Location |
| --- | --- | --- |
| Orchestrator and `[TRACK]` timeline | Server A | `C:\ProgramData\OSUpgradeAutomation\OrchestratorLogs\Orchestrator_<target>_<timestamp>.log` |
| Assessment, backup, and kickoff log | Server B | `C:\ProgramData\OSUpgradeAutomation\Logs\OSUpgradeAutomation_<timestamp>.log` |
| Phase monitor and validation log | Server B | `C:\ProgramData\OSUpgradeAutomation\Logs\Update-UpgradeStatus.log` |
| Precheck report | Server B | `D:\UpgradeBackup\PreCheckReport_<timestamp>.log` or ProgramData Logs if the backup drive was unavailable |
| Durable phase history | Server B | `D:\UpgradeBackup\<run-folder>\OSUpgradeProgress.log` |
| Recovery and host diagnostics | Server B | `D:\UpgradeBackup\<run-folder>\` |
| Services comparison | Server B | `D:\UpgradeBackup\<run-folder>\Services_PostUpgrade_Comparison.txt` |
| Live status | Server B | `D:\upgrade_status.json` and `HKLM:\SOFTWARE\OSUpgradeAutomation` |
| Windows Setup actions/errors | Server B | `C:\$WINDOWS.~BT\Sources\Panther\setupact.log` and `setuperr.log` |
| Rollback diagnostics | Server B | `C:\Windows\Logs\SetupDiag\SetupDiagResults.xml` and the copied result under ProgramData Logs when available |
| Cleanup audit | Server B | `D:\UpgradeBackup\<run-folder>\OSUpgradeCleanup_<timestamp>.log`, with `%SystemRoot%\Temp` fallback |

The run folder also holds system-state backup evidence, host diagnostics,
service snapshots, and policy exports when their steps succeed.

## Troubleshooting

| Symptom or status | Check first | Then check | Safe next action |
| --- | --- | --- | --- |
| Cannot connect, verify admin rights, or stage files | Server A orchestrator log | DNS and WinRM 5985/5986; account membership on Server B | Correct connectivity/permissions and rerun assessment |
| Assessment failed in Phase 1 | Precheck report and target kickoff log | The named failed check and its remediation text | Correct the failed prerequisite; rerun `-PrecheckOnly` |
| Backup failed in Phase 2 | Target kickoff log | Run backup folder and `wbadmin get versions` | Restore backup capability; do not bypass it in production |
| Setup was not observed within 60 seconds | Target kickoff log | `OSUpgradeSetupLaunch` task result and Panther logs | Correct the Setup/media error before a new kickoff |
| `Windows Setup Failed` after Setup disappeared | Status `Notes` and status-engine log | Panther tails and `OSUpgradeSetupLaunch` task result | Treat as terminal; investigate the captured error before retrying |
| Offline after Event 1074 / expected reboot disconnect | Server A `[TRACK]` log and last status JSON | Last durable progress entry | Continue monitoring; this can be the normal Safe OS blind window |
| Exit code `2` or Server A was interrupted | Server A orchestrator log | Current JSON/registry status on Server B | Run `-MonitorOnly`; never blindly start a second upgrade |
| Phase 99 / rollback | Panther `setuperr.log` and `setupact.log` | SetupDiag result and durable progress log | Preserve evidence, remediate the Setup cause, then plan a reviewed retry |
| `CompletedWithWarnings` | Status JSON warning fields | Services comparison and activation details in target logs | Review warnings before closing the change |
| Final live-build verification did not complete | Server A orchestrator log | Live `Win32_OperatingSystem.BuildNumber` and target status | Repair post-reboot management access and resume `-MonitorOnly` |

Never infer success from reachability, a percentage, or the disappearance of
`setup.exe`. The terminal status and independently verified live build are the
success contract.

## Cleanup

At kickoff, Server B schedules one cleanup attempt for 14 days later by
default. It runs only for terminal status; otherwise it skips safely. Cleanup
removes automation tasks, status JSON, ProgramData runtime files, and registry
state. It never removes `D:\UpgradeBackup`.

After preserving and reviewing the evidence, manual cleanup can be run on
Server B from the staged script:

```powershell
& 'C:\ProgramData\OSUpgradeAutomation\Scripts\Remove-UpgradeArtifacts.ps1' `
    -Force
```

`-Force` overrides only the terminal-status gate. It does not override an
active starter, unreadable state, mutex protection, reparse-point checks, or
unsafe paths.

## Deeper Documentation

- [PROJECT-NOTES.md](PROJECT-NOTES.md): architecture, phase model, and design decisions.
- [CHANGE-TRACKING.md](CHANGE-TRACKING.md): detailed changes, evidence, and the full lab/production acceptance runbook.
- [ImprovementsRequired.md](ImprovementsRequired.md): original customer requirements; the listed backup, diagnostics, and administrator checks are implemented.
