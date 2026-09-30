# STEP 2B v3 - boot-time profile migration (runs as SYSTEM at startup).
# Task "BootRenameProfile". Resumable and idempotent. Never copies/deletes user data.
$ErrorActionPreference = 'Continue'
$sid     = 'S-1-5-21-<YOUR-MACHINE-SID>-1001'
$newName = 'Solskjaer'   # <-- CHANGE ME: your new username
$new     = "C:\Users\$newName"
$work    = 'C:\UsernameMigration'
$backup  = 'D:\UsernameMigration_Backup'
$logDir  = "$work\logs"
New-Item -ItemType Directory -Force -Path $logDir, "$backup\config_baks" -ErrorAction SilentlyContinue | Out-Null
$log     = "$logDir\boot_rename_log.txt"
function Log($m) { $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m; $line | Tee-Object -FilePath $log -Append }
Start-Transcript -Path "$logDir\boot_rename_transcript.txt" -Append -ErrorAction SilentlyContinue | Out-Null

Start-Sleep -Seconds 15
Log '=== BOOT RENAME START (v3) ==='

$pl = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction SilentlyContinue
if (-not $pl) { Log 'FATAL: ProfileList key missing - aborting.'; Stop-Transcript; exit 1 }
$old = $pl.ProfileImagePath
$oldLeaf = Split-Path -Leaf $old
$script:OldPath = $old
$script:NewPath = $new
Log ("Old path: " + $old + "   New path: " + $new)

function Test-OldHiveLoaded { $l = (reg query HKU 2>$null) -join ' '; return ($l -match ($sid + '(?![_0-9])')) }
function Stop-Indexers { Stop-Service WSearch, SysMain -Force -ErrorAction SilentlyContinue }
function Stop-WebAdmin { Stop-Service WAS, W3SVC -Force -ErrorAction SilentlyContinue }
$h64 = 'C:\UsernameMigration\tools\handle64.exe'
function Stop-ProfileHandleHolders {
  if (-not (Test-Path $h64)) { Log 'WARN: handle64.exe missing - skip holder sweep'; return }
  $lines = & $h64 -accepteula -a -nobanner $old 2>$null
  $targets = @{}
  foreach ($ln in $lines) {
    if ($ln -match '^(.+?)\s+pid:\s+(\d+)\s') {
      $pn = $Matches[1].Trim(); $pp = [int]$Matches[2]
      if (-not $targets.ContainsKey($pp)) { $targets[$pp] = $pn }
    }
  }
  foreach ($k in @($targets.Keys)) {
    $pn = $targets[$k]
    if ($k -eq $PID) { continue }
    try {
      $svcs = Get-CimInstance Win32_Service -Filter ("ProcessId=" + $k) -ErrorAction SilentlyContinue
      if ($svcs) {
        foreach ($s in $svcs) {
          Log ('Stopping handle-holding service: ' + $s.Name + ' (' + $pn + ' pid ' + $k + ')')
          Stop-Service -Name $s.Name -Force -ErrorAction Stop
        }
      } else {
        Log ('Killing handle-holding process: ' + $pn + ' (pid ' + $k + ')')
        Stop-Process -Id $k -Force -ErrorAction Stop
      }
    } catch { Log ('WARN holder ' + $pn + ' pid ' + $k + ': ' + $_.Exception.Message) }
  }
}

function Disable-OldUserTasksHard {
  Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
    $t = $_; $uid = ''
    try { $uid = [string]$t.Principal.UserId } catch {}
    if ($uid -ne '' -and ($uid -match ($sid + '(?![_0-9])') -or $uid -like ('*' + $oldLeaf + '*'))) {
      $done = $false
      try { Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null; $done = $true }
      catch {
        $tf = 'C:\Windows\System32\Tasks' + $t.TaskPath.Replace('/', '\') + $t.TaskName
        try {
          takeown /f "$tf" 2>$null | Out-Null
          icacls "$tf" /grant *S-1-5-18:F 2>$null | Out-Null
          icacls "$tf" /grant *S-1-5-32-544:F 2>$null | Out-Null
          Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null; $done = $true
        } catch {}
      }
      if ($done) { Log ('Task disabled: ' + $t.TaskPath + $t.TaskName) } else { Log ('WARN task not disable-able (continuing anyway): ' + $t.TaskPath + $t.TaskName) }
    }
  }
}
function Stop-OldUserProcesses {
  Get-Process -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { $_.UserName -like ('*\' + $oldLeaf) } | ForEach-Object {
    try { Log ('Stopping stray process: ' + $_.ProcessName + ' [' + $_.UserName + ']'); Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {}
  }
}

if ($old -eq $new) {
  if (Test-Path -LiteralPath $new) {
    Log 'Already migrated - removing boot task.'
    Unregister-ScheduledTask -TaskName 'BootRenameProfile' -Confirm:$false -ErrorAction SilentlyContinue
    'DONE' | Set-Content -LiteralPath "$logDir\boot_rename_DONE.txt"
  } else { Log 'FATAL: registry points to Solskjaer but folder missing - manual attention needed.' }
  Stop-Transcript; exit 0
}

$oldExists = Test-Path -LiteralPath $old
$newExists = Test-Path -LiteralPath $new
if ($oldExists -and $newExists) { Log 'FATAL: both folders exist - manual attention needed.'; Stop-Transcript; exit 1 }

if ($oldExists) {
  Disable-OldUserTasksHard
  Stop-Indexers
  Stop-WebAdmin
  try { Stop-Service 'CodexSandboxService.OpenAI.Codex' -Force -ErrorAction Stop; Log 'Codex sandbox service stopped.' } catch { Log ('WARN codex service: ' + $_.Exception.Message) }
  Stop-OldUserProcesses
  Stop-ProfileHandleHolders
  Start-Sleep -Seconds 3
  if (Test-OldHiveLoaded) {
    Log 'Old user hive is loaded - checking whether it is a REAL desktop session...'
    $explorerOld = Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { $_.UserName -like ('*\' + $oldLeaf) }
    if ($explorerOld) {
      Log 'ABORT: the old user has an active desktop session (logged in before the task ran). Nothing changed. Reboot and WAIT at the login screen without signing in.'
      Stop-Transcript; exit 1
    }
    Log 'No desktop session - treating as stray background load. Killing strays and unloading the hive...'
    Stop-OldUserProcesses
    Start-Sleep -Seconds 2
    reg unload "HKU\$sid" 2>$null | Out-Null
    reg unload "HKU\$($sid)_Classes" 2>$null | Out-Null
    Start-Sleep -Seconds 2
    if (Test-OldHiveLoaded) { Log 'ABORT: hive still loaded after unload attempt - will retry next boot. Nothing changed.'; Stop-Transcript; exit 1 }
    Log 'Hive unloaded successfully.'
  }
  try { reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" "$backup\HKLM_ProfileList_before_rename.reg" /y | Out-Null } catch {}
  Get-ChildItem -LiteralPath $old -Force -Filter 'NTUSER.DAT*' -ErrorAction SilentlyContinue |
    ForEach-Object { try { Copy-Item -LiteralPath $_.FullName -Destination ("$backup\" + $_.Name + '.pre_rename') -Force -ErrorAction Stop } catch { Log ('WARN hive copy skipped: ' + $_.Exception.Message) } }
  try { Copy-Item -LiteralPath "$old\AppData\Local\Microsoft\Windows\UsrClass.dat" "$backup\UsrClass.dat.pre_rename" -Force -ErrorAction Stop } catch { Log 'WARN UsrClass copy skipped.' }
  $renamed = $false
  for ($attempt = 1; $attempt -le 10 -and -not $renamed; $attempt++) {
    try { Rename-Item -LiteralPath $old -NewName $newName -ErrorAction Stop; $renamed = $true }
    catch { Log ('Rename attempt ' + $attempt + ' blocked - retrying in 3s...'); Stop-Indexers; Stop-WebAdmin; Stop-OldUserProcesses; Stop-ProfileHandleHolders; Start-Sleep -Seconds 3 }
  }
  if (-not $renamed) {
    Log 'FATAL: rename blocked even at boot - auto-diagnostics:'
    $ic = icacls $old 2>&1 | Out-String
    Log $ic
    Log ('Loaded hives: ' + ((reg query HKU 2>$null) -join ' | '))
    Get-Process -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { $_.UserName -like ('*\' + $oldLeaf) } | ForEach-Object { Log ('ALIVE old-user process: ' + $_.ProcessName + '  ' + $_.Path) }
    Log 'Nothing changed. Will retry next boot.'
    Stop-Transcript; exit 1
  }
  Log 'Profile folder RENAMED.'
}

if (-not (Test-Path -LiteralPath $new)) { Log 'FATAL: new folder missing - manual attention needed.'; Stop-Transcript; exit 1 }

$cur = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid").ProfileImagePath
if ($cur -ne $new) {
  $ok = $false
  for ($i = 1; $i -le 5 -and -not $ok; $i++) {
    try { Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -Name ProfileImagePath -Value $new -ErrorAction Stop; $ok = $true }
    catch { Log ('Registry update attempt ' + $i + ' failed - retrying...'); Start-Sleep -Seconds 2 }
  }
  if (-not $ok) {
    Log ('FATAL CRITICAL: folder renamed but registry not updated. Recovery: sign in as SolskAdmin and run:')
    Log ('  Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $sid + '" -Name ProfileImagePath -Value "' + $new + '"')
    Stop-Transcript; exit 1
  }
}
Log 'ProfileImagePath updated.'

reg load HKU\_TmpUser "$new\NTUSER.DAT" 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
  function Fix-RegTree([string]$RootPath) {
    $item = Get-Item -LiteralPath $RootPath -ErrorAction SilentlyContinue
    if (-not $item) { return }
    foreach ($vn in $item.GetValueNames()) {
      try {
        $v = $item.GetValue($vn, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $k = $item.GetValueKind($vn)
        if ($v -is [string] -and $v -and $v.Contains($script:OldPath)) {
          $nv = $v.Replace($script:OldPath, $script:NewPath)
          Set-ItemProperty -LiteralPath $RootPath -Name $vn -Value $nv -Type $k
          Log ('REGFIX ' + $RootPath.Replace('Registry::HKEY_USERS\_TmpUser', 'HKCU') + '\' + $vn)
        }
      } catch { Log ('WARN regvalue ' + $vn + ': ' + $_.Exception.Message) }
    }
    foreach ($sk in $item.GetSubKeyNames()) { Fix-RegTree (Join-Path $RootPath $sk) }
  }
  $base = 'Registry::HKEY_USERS\_TmpUser'
  foreach ($k in @(
      'Environment',
      'Software\Microsoft\Windows\CurrentVersion\Run',
      'Software\Microsoft\Windows\CurrentVersion\RunOnce',
      'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders',
      'Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders',
      'Software\Microsoft\Windows\CurrentVersion\Lxss',
      'Software\Microsoft\OneDrive'
    )) { Fix-RegTree (Join-Path $base $k) }
  [gc]::Collect(); [gc]::WaitForPendingFinalizers()
  reg unload HKU\_TmpUser 2>$null | Out-Null
  Log 'Offline NTUSER.DAT fixes applied.'
} else { Log 'WARN: NTUSER.DAT could not be loaded - offline fixes skipped.' }

$oldBytes = @(
  @{From = [Text.Encoding]::UTF8.GetBytes($old);                   To = [Text.Encoding]::UTF8.GetBytes($new)},
  @{From = [Text.Encoding]::GetEncoding(936).GetBytes($old);       To = [Text.Encoding]::GetEncoding(936).GetBytes($new)},
  @{From = [Text.Encoding]::Unicode.GetBytes($old);                To = [Text.Encoding]::Unicode.GetBytes($new)},
  @{From = [Text.Encoding]::UTF8.GetBytes(($old -replace '\\', '/')); To = [Text.Encoding]::UTF8.GetBytes(($new -replace '\\', '/'))},
  @{From = [Text.Encoding]::GetEncoding(936).GetBytes(($old -replace '\\', '/')); To = [Text.Encoding]::GetEncoding(936).GetBytes(($new -replace '\\', '/'))}
)
function Replace-Bytes([byte[]]$Data, [byte[]]$From, [byte[]]$To) {
  $n = $Data.Count; $m = $From.Count
  if ($m -eq 0 -or $n -lt $m) { return $null }
  $out = New-Object System.Collections.Generic.List[byte]
  $i = 0; $hit = $false
  while ($i -lt $n) {
    if ($i + $m -le $n) {
      $ok2 = $true
      for ($j = 0; $j -lt $m; $j++) { if ($Data[$i + $j] -ne $From[$j]) { $ok2 = $false; break } }
      if ($ok2) { foreach ($b in $To) { $out.Add($b) }; $i += $m; $hit = $true; continue }
    }
    $out.Add($Data[$i]); $i++
  }
  if ($hit) { return ,($out.ToArray()) } else { return $null }
}
function Fix-FileBytes([string]$Path, [switch]$Quiet) {
  try {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Count -gt 100MB) { return }
    $curBytes = $bytes; $changed = $false
    foreach ($p in $oldBytes) {
      $r = Replace-Bytes $curBytes $p.From $p.To
      if ($r) { $curBytes = $r; $changed = $true }
    }
    if ($changed) {
      $bakName = ($Path -replace '[:\\/]', '_')
      Copy-Item -LiteralPath $Path -Destination "$backup\config_baks\$bakName" -Force -ErrorAction SilentlyContinue
      [IO.File]::WriteAllBytes($Path, $curBytes)
      Log ('FILEFIX ' + $Path)
    }
  } catch { if (-not $Quiet) { Log ('WARN file ' + $Path + ': ' + $_.Exception.Message) } }
}
if (Test-Path "$work\config_files_with_oldpath.txt") {
  Get-Content "$work\config_files_with_oldpath.txt" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_ -and $_.Trim()) {
      $p2 = $_.Replace($old, $new)
      if (Test-Path -LiteralPath $p2) { Fix-FileBytes $p2 }
    }
  }
}
Get-ChildItem 'C:\Windows\System32\Tasks' -Recurse -File -ErrorAction SilentlyContinue |
  ForEach-Object { Fix-FileBytes $_.FullName -Quiet }
Fix-FileBytes 'C:\Windows\System32\inetsrv\config\applicationHost.config' -Quiet
Log 'Path fixes in config/task files done.'

try {
  $u = Get-LocalUser | Where-Object { $_.SID.Value -eq $sid }
  if ($u -and $u.Name -ne $newName) { Rename-LocalUser -Name $u.Name -NewName $newName; Log ('Account renamed: ' + $u.Name + ' -> ' + $newName) }
  elseif ($u) { Log 'Account already named Solskjaer.' }
  Set-LocalUser -Name $newName -FullName $newName -ErrorAction SilentlyContinue
} catch { Log ('WARN account rename: ' + $_.Exception.Message) }

Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
  $t = $_; $uid = ''
  try { $uid = [string]$t.Principal.UserId } catch {}
  if ($uid -ne '' -and ($uid -match ($sid + '(?![_0-9])') -or $uid -like ('*' + $newName + '*') -or $uid -like ('*' + $oldLeaf + '*'))) {
    try { Enable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null; Log ('Task re-enabled: ' + $t.TaskPath + $t.TaskName) }
    catch { Log ('WARN re-enable ' + $t.TaskPath + $t.TaskName + ': ' + $_.Exception.Message) }
  }
}

sc.exe config ACE-BOOT start= boot 2>$null | Out-Null
sc.exe config "AntiCheatExpert Protection" start= manual 2>$null | Out-Null
sc.exe config "AntiCheatExpert Service" start= manual 2>$null | Out-Null
Log 'ACE anti-cheat start types restored.'

$chk = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid").ProfileImagePath
if ($chk -eq $new -and (Test-Path -LiteralPath $new)) {
  Unregister-ScheduledTask -TaskName 'BootRenameProfile' -Confirm:$false -ErrorAction SilentlyContinue
  Log '=================================================='
  Log 'SUCCESS - profile migrated. Boot task removed.'
  Log 'Sign in normally - desktop/documents all intact.'
  Log '=================================================='
  'DONE' | Set-Content -LiteralPath "$logDir\boot_rename_DONE.txt"
} else {
  Log 'FAILED final check - boot task kept, will retry next boot. SolskAdmin can recover manually.'
}
Stop-Transcript
