# Cleans residual old-username references (any case/slash/escape/encoding variant) in text files.
# Usage:
#   .\clean_residual.ps1 -OldName "你的旧用户名" -NewName "Solskjaer" -Files "C:\path\a.toml","C:\path\b.bat"
# Byte-level replacement: untouched bytes stay untouched (encoding-safe for the rest of the file).
param(
  [Parameter(Mandatory=$true)][string]$OldName,
  [Parameter(Mandatory=$true)][string]$NewName,
  [Parameter(Mandatory=$true)][string[]]$Files,
  [string]$BackupDir = "$env:USERPROFILE\Desktop\residual_baks"
)
$ErrorActionPreference = 'Continue'
$bk = $BackupDir
New-Item -ItemType Directory -Force -Path $bk | Out-Null
$pairs = @(
  @{F = [Text.Encoding]::UTF8.GetBytes($OldName);    T = [Text.Encoding]::UTF8.GetBytes($NewName)},
  @{F = [Text.Encoding]::Unicode.GetBytes($OldName); T = [Text.Encoding]::Unicode.GetBytes($NewName)},
  @{F = [Text.Encoding]::GetEncoding(936).GetBytes($OldName); T = [Text.Encoding]::GetEncoding(936).GetBytes($NewName)}
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
foreach ($f in $Files) {
  if (-not (Test-Path -LiteralPath $f)) { Write-Output ("skip (missing): " + $f); continue }
  $bytes = [IO.File]::ReadAllBytes($f)
  $cur = $bytes; $changed = $false
  foreach ($p in $pairs) {
    $r = Replace-Bytes $cur $p.F $p.T
    if ($r) { $cur = $r; $changed = $true }
  }
  if ($changed) {
    $bakName = ($f -replace '[:\\/]', '_')
    Copy-Item -LiteralPath $f -Destination "$bk\$bakName" -Force
    [IO.File]::WriteAllBytes($f, $cur)
    Write-Output ("CLEANED: " + $f)
  } else {
    Write-Output ("no-change: " + $f)
  }
}
