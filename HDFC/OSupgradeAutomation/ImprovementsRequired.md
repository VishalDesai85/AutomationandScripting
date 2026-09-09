Require System state backup to be taken instead of registry backup using wbadmin utility command. Need to first ensure windows backup feature is installed and then initiate system state backup to D:\UpgradeBackup

Please perform below under backup

Get-ComputerInfo -Property WindowsBuildLabEx,WindowsEditionID | Out-File -FilePath .\computerinfo.txt
systeminfo.exe | Out-File -FilePath systeminfo.txt
ipconfig /all | Out-File -FilePath ipconfig.txt

And save the copy under the same D:\UpgradeBackup

Check the existing user initiating connection to remote target server is part of local administrator