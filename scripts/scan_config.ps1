# Scans likely config files for hardcoded references to the old profile path.
# Output: C:\UsernameMigration\config_files_with_oldpath.txt
$ErrorActionPreference = 'SilentlyContinue'
$old = Split-Path -Leaf $env:USERPROFILE
$outFile = 'C:\UsernameMigration\config_files_with_oldpath.txt'

$roots = @(
  @{P = $env:USERPROFILE;                            D = 0}
  @{P = "$env:USERPROFILE\.ssh";                     D = 2}
  @{P = "$env:USERPROFILE\.vscode";                  D = 2}
  @{P = "$env:USERPROFILE\.config";                  D = 3}
  @{P = "$env:USERPROFILE\.codex";                   D = 3}
  @{P = "$env:USERPROFILE\.claude";                  D = 3}
  @{P = "$env:USERPROFILE\.cursor";                  D = 3}
  @{P = "$env:USERPROFILE\.gemini";                  D = 3}
  @{P = "$env:USERPROFILE\.zcode";                   D = 4}
  @{P = "$env:USERPROFILE\Documents\IISExpress";     D = 3}
  @{P = "$env:APPDATA\Code\User";                    D = 3}
  @{P = "$env:APPDATA\npm";                          D = 2}
  @{P = "$env:APPDATA\pip";                          D = 2}
  @{P = "$env:APPDATA\Docker";                       D = 2}
  @{P = "$env:APPDATA\Cursor";                       D = 2}
  @{P = "$env:APPDATA\Trae";                         D = 2}
  @{P = "$env:LOCALAPPDATA\npm-cache";               D = 0}
)

$exts = '\.(json|jsonc|config|xml|ini|conf|cfg|yaml|yml|toml|cmd|bat|ps1|sh|py|js|ts|txt|properties|env|gitconfig|npmrc|condarc|condarc\.bak)$'
$nameHits = '^\.(gitconfig|npmrc|condarc|bashrc|bash_profile|profile|wgetrc|curlrc|netrc|gitignore_global|gitcommit|pypirc)$'

$hits = New-Object System.Collections.Generic.List[string]
foreach ($r in $roots) {
  if (-not (Test-Path -LiteralPath $r.P)) { continue }
  $files = Get-ChildItem -LiteralPath $r.P -Recurse -File -Force -Depth $r.D -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Length -lt 20MB -and
      $_.Name -notlike 'ntuser*' -and
      $_.FullName -notlike '*node_modules*' -and
      $_.FullName -notlike '*\.git\*' -and
      $_.FullName -notlike '*\plugins\cache\*' -and
      ($_.Extension -match $exts -or $_.Name -match $nameHits -or $_.Name -ieq 'config')
    }
  foreach ($f in $files) {
    if (Select-String -LiteralPath $f.FullName -Pattern ([regex]::Escape($old)) -Quiet) {
      $hits.Add($f.FullName)
    }
  }
}

# Windows Terminal settings
Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter 'Microsoft.WindowsTerminal*' -ErrorAction SilentlyContinue | ForEach-Object {
  $st = Join-Path $_.FullName 'LocalState\settings.json'
  if ((Test-Path $st -PathType Leaf) -and (Select-String -LiteralPath $st -Pattern ([regex]::Escape($old)) -Quiet)) {
    $hits.Add($st)
  }
}

$hits = $hits | Sort-Object -Unique
$hits | Set-Content -LiteralPath $outFile -Encoding UTF8
Write-Output ("HITS=" + $hits.Count)
$hits | ForEach-Object { Write-Output $_ }
