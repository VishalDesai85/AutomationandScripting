<#
.SYNOPSIS
    Removes orphaned local user profile registry entries so the OS upgrade
    pre-check "Orphaned local user profiles" can pass.

.DESCRIPTION
    Shipped as a companion to Start-TargetUpgrade.ps1. When that script's
    pre-upgrade assessment finds orphaned profiles, it COPIES this file into
    its own staging folder and points the operator at it - it deliberately
    never EXECUTES it. Removing profile data is a human decision, never
    something a pre-check should do unattended.

    (Until 2026-09-26 this file did not exist on disk: its entire body was
    embedded as a 341-line here-string inside Start-TargetUpgrade.ps1 and
    written out at pre-check time. It was extracted into a real .ps1 so it
    gets syntax highlighting, linting and PSScriptAnalyzer coverage like
    every other script in this solution.)

    "Orphaned" = a SID under
    HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList that no
    longer resolves to any account (local or domain) - typically left behind
    when a user account was deleted without also removing its local profile
    via System Properties > Advanced > User Profiles > Delete.

    This script is SELF-DISCOVERING: it re-scans ProfileList at run time and
    removes WHATEVER is orphaned at that moment, so the same file keeps
    working unchanged if different/new orphaned accounts appear later. No
    SIDs are hardcoded.

    Two separate things can be removed, each confirmed independently:
      1. The ProfileList REGISTRY entries (and their .bak counterparts).
         This alone is what clears the "Account Unknown" rows from
         System Properties > Advanced > User Profiles > Settings and lets
         the upgrade pre-check pass.
      2. OPTIONALLY, the profile FOLDERS on disk (e.g. C:\Users\sam). This
         deletes REAL USER DATA and cannot be undone, so it is a second,
         explicit opt-in - answered separately, defaulting to NO.

.PARAMETER Force
    Skip the interactive confirmation prompt. Intended for a reviewed,
    deliberate unattended run - not the default. On its own, -Force still
    removes ONLY the registry entries.

.PARAMETER IncludeProfileFolder
    Also delete each orphaned profile's folder on disk. Interactively you
    are asked about this anyway; pass this switch to answer "yes" up front
    (required to delete folders during a -Force run, which never prompts).

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Remove-OrphanedProfiles.ps1

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Remove-OrphanedProfiles.ps1 -Force

.EXAMPLE
    Unattended, registry entries AND profile folders:
    powershell.exe -ExecutionPolicy Bypass -File .\Remove-OrphanedProfiles.ps1 -Force -IncludeProfileFolder
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$IncludeProfileFolder
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "This script must be run from an ELEVATED PowerShell session (Run as Administrator)."
}

function Confirm-YesNo {
    param([string]$Prompt)
    $answer = Read-Host $Prompt
    return ("$answer".Trim() -match '^(y|yes)$')
}

function Get-FolderSizeMB {
    param([string]$Path)
    try {
        $bytes = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                  Measure-Object -Property Length -Sum).Sum
        if (-not $bytes) { return 0 }
        return [math]::Round($bytes / 1MB, 1)
    } catch { return $null }
}

function Test-SafeProfileFolder {
    <#
    Guard rail for the folder-deletion path. ProfileImagePath is attacker-
    irrelevant here but IS operator-supplied data that has been wrong before
    (blank, truncated, or pointing somewhere shared), and a bad value passed
    to Remove-Item -Recurse -Force is unrecoverable - so refuse anything that
    is not clearly an individual profile directory.
    #>
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }

    $full = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\')

    # Never a drive root (e.g. "C:\").
    if ($full -match '^[A-Za-z]:$') { return $false }

    $blocked = @(
        $env:SystemRoot,
        $env:ProgramData,
        ${env:ProgramFiles},
        ${env:ProgramFiles(x86)},
        (Join-Path $env:SystemDrive 'Users'),
        $env:USERPROFILE,
        (Join-Path (Join-Path $env:SystemDrive 'Users') 'Public'),
        (Join-Path (Join-Path $env:SystemDrive 'Users') 'Default'),
        (Join-Path (Join-Path $env:SystemDrive 'Users') 'Default User'),
        (Join-Path (Join-Path $env:SystemDrive 'Users') 'All Users')
    ) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }

    foreach ($b in $blocked) {
        # Equal to, or an ANCESTOR of, anything protected.
        if ($full -ieq $b) { return $false }
        if ($b.StartsWith($full + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Invoke-NativeQuiet {
    <#
    Runs a console tool, discarding its output and returning the exit code.
    The $ErrorActionPreference dance is essential, not cosmetic: this script
    runs with 'Stop', under which ANY native command writing to stderr raises
    a terminating NativeCommandError. takeown/icacls routinely write to
    stderr for individual files while still succeeding overall, so without
    this the whole cleanup would abort partway through.
    #>
    param([string]$FilePath, [string[]]$ArgumentList)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @ArgumentList 2>&1 | Out-Null
        return $LASTEXITCODE
    } catch {
        return -1
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Remove-ProfileFolder {
    <#
    Deletes one orphaned profile folder in escalating stages, doing the least
    invasive thing that works. Only ever called on a path that already passed
    Test-SafeProfileFolder.

    Stage 1 - Remove-Item. Fails on the legacy compatibility JUNCTIONS inside
      AppData ('Application Data', 'Local Settings', ...) because it walks
      INTO them and hits their by-design deny ACE:
      "Access to the path ...\AppData\Local\Application Data is denied".
    Stage 2 - cmd's 'rd /s /q', which deletes a reparse point as a LINK
      instead of following it, and removes read-only files without asking.
      This alone fixes the junction case - no permission changes needed.
    Stage 3 - only if still present: take ownership and reset the ACLs, then
      'rd' again. 'icacls /reset' matters here because a profile owned by a
      deleted SID can carry explicit DENY entries, and /grant cannot override
      a deny - it has to be cleared.

    Escalation is deliberately LAST: 'takeown /R' and 'icacls /T' traverse
    directory junctions, so on a profile containing a junction that points
    outside itself they could rewrite ownership/permissions on unrelated
    data. Stage 2 removes those junctions first, so by the time stage 3 runs
    there is normally nothing left to traverse out of.
    #>
    param([string]$Path)

    $firstError = $null
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        $firstError = $_.Exception.Message
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Success = $true; Method = 'direct delete'; Error = $null }
    }

    Invoke-NativeQuiet -FilePath 'cmd.exe' -ArgumentList @('/c', 'rd', '/s', '/q', $Path) | Out-Null
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Success = $true; Method = 'rd /s /q (junction-safe)'; Error = $null }
    }

    Write-Host ("   Delete blocked ({0})" -f $firstError) -ForegroundColor DarkYellow
    Write-Host ("   Taking ownership and resetting permissions on {0} ..." -f $Path) -ForegroundColor Yellow

    # *S-1-5-32-544 is the built-in Administrators SID - used instead of the
    # group NAME so this still works on non-English Windows.
    Invoke-NativeQuiet -FilePath 'takeown.exe' -ArgumentList @('/F', $Path, '/R', '/A', '/D', 'Y')                           | Out-Null
    Invoke-NativeQuiet -FilePath 'icacls.exe'  -ArgumentList @($Path, '/reset', '/T', '/C', '/Q')                            | Out-Null
    Invoke-NativeQuiet -FilePath 'icacls.exe'  -ArgumentList @($Path, '/grant', '*S-1-5-32-544:(OI)(CI)F', '/T', '/C', '/Q') | Out-Null
    Invoke-NativeQuiet -FilePath 'attrib.exe'  -ArgumentList @('-R', '-S', '-H', "$Path\*", '/S', '/D')                      | Out-Null

    Invoke-NativeQuiet -FilePath 'cmd.exe' -ArgumentList @('/c', 'rd', '/s', '/q', $Path) | Out-Null
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Success = $true; Method = 'takeown + icacls reset + rd'; Error = $null }
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        $firstError = $_.Exception.Message
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Success = $true; Method = 'takeown + icacls reset + Remove-Item'; Error = $null }
    }

    return [pscustomobject]@{ Success = $false; Method = 'all methods failed'; Error = $firstError }
}

$profileListPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

# Matches the detection logic in Start-TargetUpgrade.ps1 exactly: only real
# user-account SIDs (S-1-5-21-*), so built-in/service SIDs are never touched.
# @(...) is required: with exactly ONE orphan the pipeline returns a bare
# PSCustomObject whose .Count is $null, which blanked every "N of M" message
# and made the final "$removed -eq $orphans.Count" success test fail.
$orphans = @(Get-ChildItem -Path $profileListPath -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^S-1-5-21-' } |
    ForEach-Object {
        $sid = $_.PSChildName
        $resolved = $true
        try {
            $null = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount])
        } catch { $resolved = $false }
        if (-not $resolved) {
            [pscustomobject]@{
                Sid         = $sid
                PSPath      = $_.PSPath
                ProfilePath = (Get-ItemProperty -Path $_.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
            }
        }
    })

if (-not $orphans) {
    Write-Host "No orphaned profile SIDs found under ProfileList - nothing to do." -ForegroundColor Green
    Write-Host "The 'Orphaned local user profiles' pre-check will pass; re-run the OS upgrade." -ForegroundColor Cyan
    return
}

Write-Host ""
Write-Host "The following $($orphans.Count) orphaned ProfileList registry entr(ies) will be REMOVED:" -ForegroundColor Yellow
foreach ($o in $orphans) {
    $shown = if ($o.ProfilePath) { $o.ProfilePath } else { '(unknown)' }
    $sizeText = ''
    if ($o.ProfilePath -and (Test-Path -LiteralPath $o.ProfilePath -PathType Container)) {
        $mb = Get-FolderSizeMB -Path $o.ProfilePath
        if ($null -ne $mb) { $sizeText = "  [$mb MB on disk]" }
    } elseif ($o.ProfilePath) {
        $sizeText = '  [folder no longer present]'
    }
    Write-Host ("   {0}    profile folder: {1}{2}" -f $o.Sid, $shown, $sizeText)
}
Write-Host ""
Write-Host "Removing the registry entries clears these from System Properties > Advanced >" -ForegroundColor Yellow
Write-Host "User Profiles (where they show as 'Account Unknown') and lets the upgrade" -ForegroundColor Yellow
Write-Host "pre-check pass. The profile FOLDERS above are a separate question, asked next." -ForegroundColor Yellow
Write-Host ""

$deleteFolders = [bool]$IncludeProfileFolder

if (-not $Force) {
    if (-not (Confirm-YesNo "Proceed with removing the registry entries? Type Y or YES to confirm, anything else to abort")) {
        Write-Host "Aborted - nothing was changed." -ForegroundColor Yellow
        return
    }
    if (-not $deleteFolders) {
        Write-Host ""
        Write-Host "Also delete the profile FOLDERS listed above from disk?" -ForegroundColor Red
        Write-Host "This permanently deletes REAL USER DATA (documents, desktop, profile" -ForegroundColor Red
        Write-Host "settings) and CANNOT BE UNDONE. Answer N to keep the folders - the" -ForegroundColor Red
        Write-Host "upgrade pre-check passes either way." -ForegroundColor Red
        $deleteFolders = Confirm-YesNo "Delete the profile folders too? Type Y or YES to confirm, anything else to keep them"
    }
}

if ($deleteFolders) {
    Write-Host ""
    Write-Host "Profile folders WILL be deleted along with the registry entries." -ForegroundColor Red
} else {
    Write-Host ""
    Write-Host "Profile folders will be KEPT on disk (registry entries only)." -ForegroundColor Cyan
}
Write-Host ""

$removed       = 0
$foldersOk     = 0
$foldersFailed = @()

foreach ($o in $orphans) {
    $shown = if ($o.ProfilePath) { $o.ProfilePath } else { '(unknown)' }

    # Folder first: if it fails, the registry entry is still removed below so
    # the upgrade is unblocked either way, and the leftover path is reported.
    if ($deleteFolders -and $o.ProfilePath) {
        if (Test-SafeProfileFolder -Path $o.ProfilePath) {
            $fr = Remove-ProfileFolder -Path $o.ProfilePath
            if ($fr.Success) {
                Write-Host ("Deleted profile folder: {0}  [{1}]" -f $o.ProfilePath, $fr.Method) -ForegroundColor Green
                $foldersOk++
            } else {
                Write-Host ("FAILED to delete profile folder {0} even after taking ownership: {1}" -f $o.ProfilePath, $fr.Error) -ForegroundColor Red
                Write-Host "   A file there is most likely still open/locked by a running process." -ForegroundColor Red
                $foldersFailed += $o.ProfilePath
            }
        } elseif (Test-Path -LiteralPath $o.ProfilePath) {
            Write-Host ("SKIPPED folder '{0}' - not a safe individual profile directory (system/shared/root path). Delete it manually if it really is unwanted." -f $o.ProfilePath) -ForegroundColor Yellow
            $foldersFailed += $o.ProfilePath
        } else {
            Write-Host ("Profile folder '{0}' does not exist - nothing to delete." -f $o.ProfilePath) -ForegroundColor DarkGray
        }
    }

    try {
        Remove-Item -Path $o.PSPath -Recurse -Force
        $bak = $o.PSPath + '.bak'
        if (Test-Path $bak) { Remove-Item -Path $bak -Recurse -Force }
        Write-Host ("Removed orphaned ProfileList entry: {0} (was: {1})" -f $o.Sid, $shown) -ForegroundColor Green
        $removed++
    } catch {
        Write-Host ("FAILED to remove {0}: {1}" -f $o.Sid, $_) -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "$removed of $($orphans.Count) orphaned ProfileList entr(ies) removed." -ForegroundColor Green
if ($deleteFolders) {
    Write-Host "$foldersOk profile folder(s) deleted from disk." -ForegroundColor Green
    if ($foldersFailed.Count -gt 0) {
        Write-Host "The following folder(s) were NOT deleted and remain on disk - remove them manually if intended:" -ForegroundColor Yellow
        $foldersFailed | ForEach-Object { Write-Host ("   " + $_) -ForegroundColor Yellow }
    }
} else {
    Write-Host "Profile folders were left on disk. Note the ProfileList entries are now gone," -ForegroundColor Cyan
    Write-Host "so the User Profiles dialog can no longer delete them - use Remove-Item if wanted." -ForegroundColor Cyan
}
if ($removed -eq $orphans.Count) {
    Write-Host "NEXT STEP: re-run the OS upgrade from Server A (same command as before) -" -ForegroundColor Cyan
    Write-Host "the 'Orphaned local user profiles' pre-check will now pass." -ForegroundColor Cyan
} else {
    Write-Host "Some entries could not be removed - resolve those before re-running the upgrade." -ForegroundColor Yellow
}
