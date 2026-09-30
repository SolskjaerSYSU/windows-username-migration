# STEP 2 - THE CORE MIGRATION.  Run ELEVATED while signed in as SolskAdmin.
# Sign out of the old account first (log off / reboot), sign in as SolskAdmin,
# then run this script. It renames the profile folder, fixes the registry,
# fixes hardcoded paths in known config files and scheduled task files,
# and renames the account itself.  It never deletes or copies user files:
# the profile move is a pure RENAME (metadata only, instant).
$ErrorActionPreference = 'Stop'
$work    = 'C:\UsernameMigration'
$log     = "$work\logs\step2_rename_log.txt"
$sid     = 'S-1-5-21-<YOUR-MACHINE-SID>-1001'
$newName = 'Solskjaer'   # <-- CHANGE ME: your new username
$new     = "C:\Users\$newName"
$backup  = 'D:\UsernameMigration_Backup'
New-Item -ItemType Directory -Force -Path "$work\logs", "$backup\config_baks" | Out-Null

function Log($m) { $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m; $line | Tee-Object -FilePath $log -Append }
function Fatal($m) { Log ("FATAL: " + $m); Log 'Nothing was changed. Fix the problem and re-run.'; Read-Host 'Press Enter to close'; exit 1 }

Start-Transcript -Path "$work\logs\step2_transcript.txt" -Append | Out-Null
Log '=== STEP 2 START ==='

# ---------- 0. sanity checks (nothing changed yet) ----------
if ($env:USERNAME -ine 'SolskAdmin') { Fatal "You are logged in as '$env:USERNAME'. Sign in as SolskAdmin and re-run." }

$pl = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction SilentlyContinue
if (-not $pl) { Fatal "ProfileList\$sid not found in registry." }
$old     = $pl.ProfileImagePath
$oldLeaf = Split-Path -Leaf $old
$script:OldPath = $old
$script:NewPath = $new
Log "Old profile: $old"
Log "New profile: $new"

if ($old -eq $new) { Log 'ProfileImagePath already points to Solskjaer - nothing to do (already migrated?).'; Read-Host 'Press Enter to close'; exit 0 }
if ($oldLeaf -ieq $newName) { Fatal "Old folder leaf equals new name - unexpected." }
if (-not (Test-Path -LiteralPath $old)) { Fatal "Old profile folder '$old' not found." }
if (Test-Path -LiteralPath $new) { Fatal "Target '$new' already exists." }
if ($env:USERPROFILE -like "$old*") { Fatal "Old profile is in use by this session." }

# ---------- 1. make sure the OLD account is fully signed out (before anything) ----------
$loadedList = (reg query HKU 2>$null) -join ' '
if ($loadedList -match [regex]::Escape($sid)) {
  Fatal "The OLD account is still signed in (its registry hive is loaded). Click Start > Power > RESTART (do not use Switch user), then sign in as SolskAdmin and run this again."
}
$oldLeaf2 = Split-Path -Leaf $old
$script:disabledTasks = New-Object System.Collections.Generic.List[string]
function Disable-OldUserTasks {
  Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
    $t = $_
    $uid = ''
    try { $uid = [string]$t.Principal.UserId } catch {}
    if ($uid -ne '' -and ($uid -match ($sid + '(?![_0-9])') -or $uid -like ('*' + $oldLeaf2 + '*'))) {
      try {
        Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null
        if (-not $script:disabledTasks.Contains($t.TaskPath + $t.TaskName)) { $script:disabledTasks.Add($t.TaskPath + $t.TaskName) }
        Log ('Task disabled: ' + $t.TaskPath + $t.TaskName)
      } catch { Log ('WARN could not disable task ' + $t.TaskPath + $t.TaskName + ': ' + $_.Exception.Message) }
    }
  }
}
function Stop-OldUserProcesses {
  Get-Process -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { $_.UserName -like ('*\' + $oldLeaf2) } | ForEach-Object {
    try { Log ('Stopping stray process: ' + $_.ProcessName + ' [' + $_.UserName + ']'); Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {}
  }
}
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
function Test-OldHiveLoaded {
  $l = (reg query HKU 2>$null) -join ' '
  return ($l -match ($sid + '(?![_0-9])'))
}
if (Test-OldHiveLoaded) {
  Log 'Old user hive is loaded - disabling its tasks, stopping its stray processes, unloading it...'
  Disable-OldUserTasks
  Stop-OldUserProcesses
  Start-Sleep -Seconds 2
  reg unload "HKU\$sid" 2>$null | Out-Null
  reg unload "HKU\$($sid)_Classes" 2>$null | Out-Null
  Start-Sleep -Seconds 1
}
if (Test-OldHiveLoaded) {
  Fatal "The OLD account's registry hive is still loaded and could not be unloaded. Click Start > Power > RESTART, sign in as SolskAdmin, wait ONE minute, then run this again."
}
Disable-OldUserTasks
Stop-Indexers
Stop-WebAdmin
try { Stop-Service 'CodexSandboxService.OpenAI.Codex' -Force -ErrorAction Stop; Log 'Codex sandbox service stopped.' } catch { Log ('WARN codex service: ' + $_.Exception.Message) }
Stop-OldUserProcesses
Stop-ProfileHandleHolders

# ---------- 2. hive lock probe (fails = old user still logged in) ----------
reg load HKU\_RenameProbe "$old\NTUSER.DAT" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Fatal "NTUSER.DAT is locked - the old account is still logged in. Click Start > Power > RESTART (not Switch user / not Shut down), sign in as SolskAdmin, then re-run." }
reg unload HKU\_RenameProbe | Out-Null
Log 'Hive lock probe passed.'

# ---------- 3. extra backups (hive copies + registry exports) ----------
try {
  reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" "$backup\HKLM_ProfileList_before_rename.reg" /y | Out-Null
  Log 'ProfileList exported.'
} catch { Log ('WARN ProfileList export: ' + $_.Exception.Message) }

Get-ChildItem -LiteralPath $old -Force -Filter 'NTUSER.DAT*' -ErrorAction SilentlyContinue |
  ForEach-Object { try { Copy-Item -LiteralPath $_.FullName -Destination ("$backup\" + $_.Name + '.pre_rename') -Force -ErrorAction Stop } catch { Log ('WARN hive copy skipped: ' + $_.Exception.Message) } }
try { Copy-Item -LiteralPath "$old\AppData\Local\Microsoft\Windows\UsrClass.dat" "$backup\UsrClass.dat.pre_rename" -Force -ErrorAction Stop; Log 'Hive file copies saved to backup drive.' } catch { Log 'WARN: UsrClass copy skipped (non-fatal).' }

# ---------- 3. THE RENAME (metadata only, no data copy) ----------
$renamed = $false
for ($attempt = 1; $attempt -le 8 -and -not $renamed; $attempt++) {
  try {
    Rename-Item -LiteralPath $old -NewName $newName -ErrorAction Stop
    $renamed = $true
  } catch {
    Log ('Rename attempt ' + $attempt + ' blocked (' + $_.Exception.Message.Trim() + ') - clearing strays and retrying in 3s...')
    Stop-OldUserProcesses
    Stop-Indexers
    Stop-WebAdmin
    Stop-ProfileHandleHolders
    Start-Sleep -Seconds 3
  }
}
if (-not $renamed) {
  Fatal "Windows is still holding the profile folder. Click Start > Power > RESTART, sign in as SolskAdmin, wait ONE minute, then run this again. Nothing has been changed."
}
if (-not (Test-Path -LiteralPath $new)) { Fatal "Rename reported success but target missing - rename back manually: Rename-Item '$new' '$oldLeaf'" }
Log 'Profile folder RENAMED.'

# ---------- 4. registry ProfileImagePath ----------
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -Name ProfileImagePath -Value $new
Log 'HKLM ProfileImagePath updated.'

# ---------- 5. offline NTUSER.DAT fixes ----------
reg load HKU\_TmpUser "$new\NTUSER.DAT" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Log 'WARN: could not load NTUSER.DAT for offline fixes (it will still load normally at logon).' }
else {
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
          Log ("REGFIX " + $RootPath.Replace('Registry::HKEY_USERS\_TmpUser','HKCU') + "\" + $vn)
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
    )) {
    Fix-RegTree (Join-Path $base $k)
  }
  [gc]::Collect(); [gc]::WaitForPendingFinalizers()
  reg unload HKU\_TmpUser 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { Log 'WARN: NTUSER.DAT unload nonzero (usually harmless; Windows releases it at logon).' }
  else { Log 'Offline NTUSER.DAT fixes applied and hive unloaded cleanly.' }
}

# ---------- 6. hardcoded paths in known config files (byte-level, with .bak) ----------
$oldBytes = @(
  @{From = [Text.Encoding]::UTF8.GetBytes($old);                    To = [Text.Encoding]::UTF8.GetBytes($new)},
  @{From = [Text.Encoding]::GetEncoding(936).GetBytes($old);        To = [Text.Encoding]::GetEncoding(936).GetBytes($new)},
  @{From = [Text.Encoding]::Unicode.GetBytes($old);                 To = [Text.Encoding]::Unicode.GetBytes($new)},
  @{From = [Text.Encoding]::UTF8.GetBytes(($old -replace '\\','/'));  To = [Text.Encoding]::UTF8.GetBytes(($new -replace '\\','/'))},
  @{From = [Text.Encoding]::GetEncoding(936).GetBytes(($old -replace '\\','/')); To = [Text.Encoding]::GetEncoding(936).GetBytes(($new -replace '\\','/'))}
)
function Replace-Bytes([byte[]]$Data, [byte[]]$From, [byte[]]$To) {
  $n = $Data.Count; $m = $From.Count
  if ($m -eq 0 -or $n -lt $m) { return $null }
  $out = New-Object System.Collections.Generic.List[byte]
  $i = 0; $hit = $false
  while ($i -lt $n) {
    if ($i + $m -le $n) {
      $ok = $true
      for ($j = 0; $j -lt $m; $j++) { if ($Data[$i + $j] -ne $From[$j]) { $ok = $false; break } }
      if ($ok) { foreach ($b in $To) { $out.Add($b) }; $i += $m; $hit = $true; continue }
    }
    $out.Add($Data[$i]); $i++
  }
  if ($hit) { return ,($out.ToArray()) } else { return $null }
}
function Fix-FileBytes([string]$Path, [switch]$Quiet) {
  try {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Count -gt 100MB) { return }
    $cur = $bytes; $changed = $false
    foreach ($p in $oldBytes) {
      $r = Replace-Bytes $cur $p.From $p.To
      if ($r) { $cur = $r; $changed = $true }
    }
    if ($changed) {
      $bakName = ($Path -replace '[:\\/]', '_')
      Copy-Item -LiteralPath $Path -Destination "$backup\config_baks\$bakName" -Force -ErrorAction SilentlyContinue
      [IO.File]::WriteAllBytes($Path, $cur)
      Log ("FILEFIX " + $Path)
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
  Log 'Config file fixes done.'
} else { Log 'NOTE: config scan list missing - run scan_config.ps1 as the old user beforehand.' }

# scheduled task XML files (UTF-16) under C:\Windows\System32\Tasks
Get-ChildItem 'C:\Windows\System32\Tasks' -Recurse -File -ErrorAction SilentlyContinue |
  ForEach-Object { Fix-FileBytes $_.FullName -Quiet }
Fix-FileBytes 'C:\Windows\System32\inetsrv\config\applicationHost.config' -Quiet
Log 'Scheduled task file fixes done.'

# re-enable the tasks disabled earlier (their paths are fixed now)
foreach ($tp in $script:disabledTasks) {
  $tn = Split-Path -Leaf $tp
  $tpath = $tp.Substring(0, $tp.Length - $tn.Length)
  if ($tpath -eq '') { $tpath = '\' }
  try { Enable-ScheduledTask -TaskPath $tpath -TaskName $tn -ErrorAction Stop | Out-Null; Log ('Task re-enabled: ' + $tp) }
  catch { Log ('WARN re-enable task ' + $tp + ': ' + $_.Exception.Message) }
}

# ---------- 7. rename the account itself ----------
try {
  $u = Get-LocalUser | Where-Object { $_.SID.Value -eq $sid }
  if ($u -and $u.Name -ine $newName) {
    Rename-LocalUser -Name $u.Name -NewName $newName
    Log ("Account renamed: " + $u.Name + " -> " + $newName)
  }
  Set-LocalUser -Name $newName -FullName $newName -ErrorAction SilentlyContinue
  Log 'Account full name set to Solskjaer.'
} catch { Log ('WARN account rename: ' + $_.Exception.Message) }

sc.exe config ACE-BOOT start= boot 2>$null | Out-Null
sc.exe config "AntiCheatExpert Protection" start= manual 2>$null | Out-Null
sc.exe config "AntiCheatExpert Service" start= manual 2>$null | Out-Null
Log 'ACE anti-cheat start types restored.'

# ---------- 8. final verification ----------
$chk = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid").ProfileImagePath
if ($chk -eq $new -and (Test-Path -LiteralPath $new)) {
  Log '=============================='
  Log 'SUCCESS - profile migrated.'
  Log 'Next: reboot and sign in as yourself (PIN/password unchanged).'
  Log '=============================='
} else {
  Log '=============================='
  Log 'FAILED FINAL CHECK - rollback: rename folder back and restore ProfileImagePath from the exported .reg files.'
  Log '=============================='
}
Stop-Transcript | Out-Null
Read-Host 'Press Enter to close'
