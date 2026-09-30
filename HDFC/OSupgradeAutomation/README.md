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

- The repository layout above is intact. The orchestrator requires all six
  target-side files and refuses to start if one is missing.
- The account used by Server A is a local administrator on Server B. The
  orchestrator verifies this again before staging.
- Server B is reachable through WinRM HTTP/5985 or HTTPS/5986.
- Server B has exactly one suitable ISO under `D:\ISO`, at least 32 GB free
    on the system drive, and `D:\UpgradeBackup` available.
- A maintenance window, recovery plan, and recoverable lab validation exist
  for the real source OS, target media, edition, and credentials.

Other defaults are `D:\upgrade_status.json` for live status,
`C:\Temp\OSUpgradeStaging` for staging, and
`C:\ProgramData\OSUpgradeAutomation` for target runtime files.

Do not use `-SkipPatchCheckLab`, `-SkipDismScanHealthLab`,
`-SkipSfcScanNowLab`, or `-SkipSystemStateBackup` for production acceptance or
a production upgrade. Those switches intentionally leave required evidence
unverified or missing.

## Run It

Run the following commands from the repository root on Server A.

### 1. Validate the package safely

This does not start an upgrade, write the registry, create scheduled tasks, or
delete files.

```powershell
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File '.\Tests\Run-SafeTests.ps1'
```

Stop if the safe suite fails.

### 2. Run assessment only

Assessment writes reports and may temporarily mount media. It does not run the
backup phase and does not launch Windows Setup.

```powershell
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File '.\ServerA-Orchestrator\Start-RemoteUpgradeOrchestrator.ps1' `
    -TargetComputer 'ServerB.contoso.com' `
    -IsoFolder 'D:\ISO' `
    -PrecheckOnly

$LASTEXITCODE
```

Exit `0` with `Status=AssessmentPassed` means the assessment passed. It does
not mean the operating system was upgraded.

### 3. Run the full upgrade

```powershell
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File '.\ServerA-Orchestrator\Start-RemoteUpgradeOrchestrator.ps1' `
    -TargetComputer 'ServerB.contoso.com' `
    -IsoFolder 'D:\ISO' `
    -BackupRoot 'D:\UpgradeBackup' `
    -StatusJsonPath 'D:\upgrade_status.json' `
    -TimeoutMinutes 240

$LASTEXITCODE
```

### 4. Resume observation without starting anything

Use this after Server A was closed/restarted or the prior monitor returned exit
code `2`.

```powershell
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File '.\ServerA-Orchestrator\Start-RemoteUpgradeOrchestrator.ps1' `
    -TargetComputer 'ServerB.contoso.com' `
    -StatusJsonPath 'D:\upgrade_status.json' `
    -MonitorOnly `
    -TimeoutMinutes 120
```

`-MonitorOnly` never stages files, performs assessment/backup, or starts Setup.
Do not rerun a normal kickoff merely because monitoring timed out.

For alternate credentials, create `$cred = Get-Credential` and pass
`-Credential $cred`. Pass `-UseSSL` to require WinRM HTTPS/5986.
`-SkipCertificateCheck` weakens server identity validation and must not be used
in production. For every parameter and example:

```powershell
Get-Help '.\ServerA-Orchestrator\Start-RemoteUpgradeOrchestrator.ps1' -Full
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
