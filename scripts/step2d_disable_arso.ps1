# Elevated final preparation:
# 1) Disables Automatic Restart Sign-On (ARSO) so the PC really stops at the login screen.
# 2) Forces AutoAdminLogon off.
# 3) Reports boot task status and IIS config references to the old username.
$ErrorActionPreference = 'Continue'
$log = 'C:\UsernameMigration\logs\step2d_log.txt'
function Log($m) { $m | Tee-Object -FilePath $log -Append }
Log '=== STEP2D START ==='

reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v DisableAutomaticRestartSignOn /t REG_DWORD /d 1 /f 2>&1 | Out-Null
$v = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -ErrorAction SilentlyContinue).DisableAutomaticRestartSignOn
Log ('ARSO policy DisableAutomaticRestartSignOn = ' + $v + '  (1 = auto sign-in after restart is OFF)')

reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f 2>&1 | Out-Null
Log 'AutoAdminLogon forced to 0.'

try { $i = Get-ScheduledTaskInfo -TaskName BootRenameProfile -ErrorAction Stop; Log ('Boot task LastRun: ' + $i.LastRunTime + '  ResultCode: ' + $i.LastTaskResult) } catch { Log ('Boot task info unavailable: ' + $_.Exception.Message) }
try { $t = Get-ScheduledTask -TaskName BootRenameProfile -ErrorAction Stop; Log ('Boot task State: ' + $t.State) } catch { Log ('Boot task MISSING: ' + $_.Exception.Message) }

try {
  $content = Get-Content 'C:\Windows\System32\inetsrv\config\applicationHost.config' -ErrorAction Stop
  $pat = Split-Path -Leaf $env:USERPROFILE   # old username (this script runs AS the old user, pre-migration)
  $hits = $content | Select-String -SimpleMatch $pat
  if ($hits) {
    Log ('IIS config references to old username: ' + $hits.Count + ' hit(s)')
    $hits | Select-Object -First 5 | ForEach-Object { Log ('  line ' + $_.LineNumber + ': ' + $_.Line.Trim()) }
  } else { Log 'IIS config: no old username references' }
} catch { Log ('IIS config unreadable: ' + $_.Exception.Message) }

Log '=== STEP2D DONE ==='
Write-Host 'ALL PREPARATIONS DONE. You can close this window and restart.'
Read-Host 'Press Enter to close'
