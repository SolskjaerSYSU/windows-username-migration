# STEP 3 - verification. Run AFTER migrating and signing back in normally.
# Safe, read-only. No admin required.
# Usage: .\step3_verify.ps1 -OldName "你的旧用户名" -NewName "Solskjaer"
# (SID is derived automatically from the current logon session.)
param(
  [Parameter(Mandatory=$true)][string]$OldName,
  [Parameter(Mandatory=$true)][string]$NewName
)
$ErrorActionPreference = 'Continue'
$work  = "$env:TEMP"
$log   = "$work\step3_verify_log.txt"
$sid   = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$new   = "C:\Users\$NewName"
$oldLeaf = $OldName
$old   = "C:\Users\$oldLeaf"
$results = New-Object System.Collections.Generic.List[string]
function Check($name, $ok, $detail) {
  $tag = 'PASS'; if (-not $ok) { $tag = 'FAIL' }
  $line = "[$tag] $name :: $detail"
  $results.Add($line)
  $line | Tee-Object -FilePath $log -Append
}

Check 'USERPROFILE'  ($env:USERPROFILE -eq $new)              "env USERPROFILE = $env:USERPROFILE"
Check 'Account name' ($env:USERNAME -ieq $NewName)            "whoami = $env:COMPUTERNAME\$env:USERNAME"
$pl = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction SilentlyContinue).ProfileImagePath
Check 'Registry profile path' ($pl -eq $new)                  "ProfileImagePath = $pl"
Check 'New folder exists'     (Test-Path -LiteralPath $new)   $new

$bad = @()
[Environment]::GetEnvironmentVariables('User').GetEnumerator() | ForEach-Object {
  if ("$($_.Key)=$($_.Value)" -like "*$old*") { $bad += $_.Key }
}
Check 'User env vars clean' ($bad.Count -eq 0)  $(if ($bad.Count) { 'still old path: ' + ($bad -join ',') } else { 'no old path left' })

$usf = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue
$missing = @()
$usf.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object {
  $p = [Environment]::ExpandEnvironmentVariables([string]$_.Value)
  if ($p -like "$new*" -and -not (Test-Path -LiteralPath $p)) { $missing += ("$($_.Name) -> " + $p) }
}
Check 'Shell folders valid' ($missing.Count -eq 0) $(if ($missing.Count) { $missing -join '; ' } else { 'all point to existing dirs' })

$git = & git config --global --list 2>$null
Check 'git global config readable' ($LASTEXITCODE -eq 0) $(if ($git) { ($git | Select-Object -First 3) -join ' | ' } else { 'empty or git missing' })
Check '.ssh present'  (Test-Path "$new\.ssh") "$new\.ssh"

$dang = Get-ChildItem -LiteralPath $new -Recurse -Force -Depth 3 -ErrorAction SilentlyContinue |
  Where-Object { $_.LinkType -and ("$($_.Target)" -like "*$old*") }
Check 'No dangling links' (-not $dang) $(if ($dang) { $dang.FullName -join '; ' } else { 'none' })

function Log($m) { $m | Tee-Object -FilePath $log -Append }
$fail = ($results | Where-Object { $_.StartsWith('[FAIL]') }).Count
Log '------------------------------'
if ($fail -eq 0) { Log "ALL CHECKS PASSED ($($results.Count)/$($results.Count)). Migration complete." }
else { Log "$fail check(s) FAILED - review the [FAIL] lines above." }
Log '------------------------------'
Read-Host 'Press Enter to close'
