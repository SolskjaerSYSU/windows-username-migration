# STEP 1  -  run ELEVATED (as Administrator).
# Creates the recovery admin account "SolskAdmin" and a system restore point.
# This script changes nothing else. Safe to re-run.
$ErrorActionPreference = 'Continue'
$work = 'C:\UsernameMigration'
$log  = "$work\logs\step1_log.txt"
New-Item -ItemType Directory -Force -Path "$work\logs" | Out-Null
function Log($m) { $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m; $line | Tee-Object -FilePath $log -Append }

Log '=== STEP 1 START ==='

if (Get-LocalUser -Name 'SolskAdmin' -ErrorAction SilentlyContinue) {
  Log 'SolskAdmin already exists - skip creation.'
} else {
  try {
    $sec = ConvertTo-SecureString '<SET-YOUR-OWN-TEMP-PASSWORD>' -AsPlainText -Force
    New-LocalUser -Name 'SolskAdmin' -Password $sec -FullName 'SolskAdmin (recovery)' `
      -Description 'Temporary recovery admin for profile rename' -PasswordNeverExpires -AccountNeverExpires | Out-Null
    Log 'SolskAdmin created.'
  } catch { Log ("FATAL: cannot create SolskAdmin: " + $_.Exception.Message) }
}
Add-LocalGroupMember -Group 'Administrators' -Member 'SolskAdmin' -ErrorAction SilentlyContinue
Log ('Administrators now: ' + ((Get-LocalGroupMember Administrators -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', '))

try {
  Enable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue
  Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' `
    -Name 'SystemRestorePointCreationFrequency' -Value 0 -Type DWord -ErrorAction SilentlyContinue
  Checkpoint-Computer -Description 'Before profile rename to Solskjaer' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
  Log 'System restore point created OK.'
} catch {
  Log ('Restore point FAILED (non-fatal, registry backups still exist): ' + $_.Exception.Message)
}

if (Test-Path 'C:\Users\Solskjaer') { Log 'WARNING: C:\Users\Solskjaer already exists - investigate before step2!' }
else { Log 'C:\Users\Solskjaer is free - OK.' }

Log '=== STEP 1 DONE ==='
Write-Host ''
Write-Host 'STEP 1 FINISHED - you may close this window and reboot.'
Read-Host 'Press Enter to close'
