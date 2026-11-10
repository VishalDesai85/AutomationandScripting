#requires -Version 5.1
<#
.SYNOPSIS
Creates a reviewed Sysprep answer file for the Hyper-V lab parent image.
.DESCRIPTION
Run inside the reference VM before Sysprep. The script writes and validates an
unattend file that automates OOBE, sets the built-in Administrator password,
and performs one automatic Administrator logon. It does not launch Sysprep.
.EXAMPLE
.\Prepare-HyperVLabTemplate.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$OutputPath = 'C:\HyperVLab\Unattend.xml',
    [ValidatePattern('^[A-Za-z]{2}-[A-Za-z]{2}$')]
    [string]$InputLocale = 'en-IN',
    [ValidatePattern('^[A-Za-z]{2}-[A-Za-z]{2}$')]
    [string]$SystemLocale = 'en-IN',
    [ValidatePattern('^[A-Za-z]{2}-[A-Za-z]{2}$')]
    [string]$UILanguage = 'en-IN',
    [ValidatePattern('^[A-Za-z]{2}-[A-Za-z]{2}$')]
    [string]$UserLocale = 'en-IN',
    [string]$TimeZone = 'India Standard Time',
    [PSCredential]$AdministratorCredential,
    [switch]$Force
)

function ConvertTo-UnattendHiddenValue {
    param(
        [Security.SecureString]$Password,
        [ValidateSet('AdministratorPassword', 'Password')]
        [string]$SettingName
    )

    $pointer = [IntPtr]::Zero
    $plainText = $null
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $plainText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        return [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes($plainText + $SettingName)
        )
    }
    finally {
        $plainText = $null
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
}

function ConvertTo-UnattendXmlText {
    param([string]$Value)

    return [Security.SecurityElement]::Escape($Value)
}

function New-HyperVLabUnattend {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$OutputPath,
        [string]$InputLocale,
        [string]$SystemLocale,
        [string]$UILanguage,
        [string]$UserLocale,
        [string]$TimeZone,
        [PSCredential]$AdministratorCredential,
        [switch]$Force
    )

    $ErrorActionPreference = 'Stop'
    if ($null -eq $AdministratorCredential) {
        $AdministratorCredential = Get-Credential -UserName 'Administrator' `
            -Message 'Enter the built-in Administrator password for cloned lab VMs.'
        if ($null -eq $AdministratorCredential) {
            throw 'Administrator credential entry was cancelled.'
        }
    }
    if (($AdministratorCredential.UserName -split '\\')[-1] -ine 'Administrator') {
        throw "The credential username must be the built-in 'Administrator' account."
    }

    $resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    if ((Test-Path -LiteralPath $resolvedOutput) -and -not $Force) {
        throw "Unattend file '$resolvedOutput' already exists. Use -Force to replace it."
    }
    if (-not $PSCmdlet.ShouldProcess($resolvedOutput, 'Create OOBE automation answer file')) {
        return
    }

    $administratorPassword = ConvertTo-UnattendHiddenValue `
        -Password $AdministratorCredential.Password -SettingName AdministratorPassword
    $autoLogonPassword = ConvertTo-UnattendHiddenValue `
        -Password $AdministratorCredential.Password -SettingName Password
    $safeInputLocale = ConvertTo-UnattendXmlText $InputLocale
    $safeSystemLocale = ConvertTo-UnattendXmlText $SystemLocale
    $safeUILanguage = ConvertTo-UnattendXmlText $UILanguage
    $safeUserLocale = ConvertTo-UnattendXmlText $UserLocale
    $safeTimeZone = ConvertTo-UnattendXmlText $TimeZone

    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>*</ComputerName>
      <TimeZone>$safeTimeZone</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>$safeInputLocale</InputLocale>
      <SystemLocale>$safeSystemLocale</SystemLocale>
      <UILanguage>$safeUILanguage</UILanguage>
      <UserLocale>$safeUserLocale</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <TimeZone>$safeTimeZone</TimeZone>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$administratorPassword</Value>
          <PlainText>false</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <AutoLogon>
        <Password>
          <Value>$autoLogonPassword</Value>
          <PlainText>false</PlainText>
        </Password>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Username>Administrator</Username>
      </AutoLogon>
    </component>
  </settings>
</unattend>
"@

    $directory = Split-Path -Parent $resolvedOutput
    if (-not (Test-Path -LiteralPath $directory)) {
        [void](New-Item -Path $directory -ItemType Directory -ErrorAction Stop)
    }
    [IO.File]::WriteAllText($resolvedOutput, $xml, [Text.UTF8Encoding]::new($false))

    try {
        [xml]$validated = Get-Content -LiteralPath $resolvedOutput -Raw -ErrorAction Stop
    }
    catch {
        throw "Generated unattend file '$resolvedOutput' is not valid XML: $($_.Exception.Message)"
    }
    $namespace = [Xml.XmlNamespaceManager]::new($validated.NameTable)
    $namespace.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
    $requiredNodes = @(
        '//u:settings[@pass="oobeSystem"]/u:component[@name="Microsoft-Windows-International-Core"]/u:UILanguage',
        '//u:settings[@pass="oobeSystem"]/u:component[@name="Microsoft-Windows-Shell-Setup"]/u:OOBE/u:HideLocalAccountScreen',
        '//u:settings[@pass="oobeSystem"]/u:component[@name="Microsoft-Windows-Shell-Setup"]/u:UserAccounts/u:AdministratorPassword/u:Value',
        '//u:settings[@pass="oobeSystem"]/u:component[@name="Microsoft-Windows-Shell-Setup"]/u:AutoLogon/u:LogonCount'
    )
    foreach ($xpath in $requiredNodes) {
        if ($null -eq $validated.SelectSingleNode($xpath, $namespace)) {
            throw "Generated unattend file is missing required node '$xpath'."
        }
    }

    $sysprepPath = Join-Path $env:SystemRoot 'System32\Sysprep\Sysprep.exe'
    $sysprepCommand = "& `"$sysprepPath`" /generalize /oobe /mode:vm /shutdown /unattend:`"$resolvedOutput`""
    Write-Warning 'The password values are hidden, not encrypted. Protect and delete the unattend file after the template is generalized.'
    Write-Host "`nReview the generated file, then run this command inside the reference VM as Administrator:"
    Write-Host $sysprepCommand
    [pscustomobject]@{
        UnattendPath = $resolvedOutput
        SysprepCommand = $sysprepCommand
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    New-HyperVLabUnattend -OutputPath $OutputPath -InputLocale $InputLocale `
        -SystemLocale $SystemLocale -UILanguage $UILanguage -UserLocale $UserLocale `
        -TimeZone $TimeZone -AdministratorCredential $AdministratorCredential `
        -Force:$Force -WhatIf:$WhatIfPreference
}
