<#
.SYNOPSIS
    Parse the automation and run isolated regression tests without upgrading a server.
.PARAMETER Analyze
    Also require PSScriptAnalyzer and reject Error-severity findings in production scripts.
#>
[CmdletBinding()]
param([switch]$Analyze)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scripts = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -Recurse -File)
foreach ($script in $scripts) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) { throw "Syntax errors in $($script.FullName): $($parseErrors -join '; ')" }
}
Write-Host "Syntax validation passed for $($scripts.Count) PowerShell files."
foreach ($test in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File | Sort-Object Name)) {
    Write-Host "Running $($test.Name)"
    & $test.FullName
}
if ($Analyze) {
    Get-Command Invoke-ScriptAnalyzer -ErrorAction Stop | Out-Null
    $findings = @(
        foreach ($folder in @('ServerA-Orchestrator', 'ServerB-Target')) {
            Invoke-ScriptAnalyzer -Path (Join-Path $root $folder) -Recurse -Severity Error
        }
    )
    if ($findings.Count) { throw ($findings | Format-Table ScriptName, Line, RuleName, Message -Wrap | Out-String) }
    Write-Host 'PSScriptAnalyzer: no Error-severity findings.'
}
Write-Host 'All safe tests passed. No operational entry point was executed.'
